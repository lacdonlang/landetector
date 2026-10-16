import AppKit
import LanDetectorKit
import class Network.NWPathMonitor
import SwiftUI

enum SidebarItem: Hashable {
    case all, online, offline, recent, favorites
    case kind(DeviceKind)
}

enum ViewMode: String, CaseIterable {
    case table, grid
}

struct SidebarCounts {
    var all = 0, online = 0, offline = 0, recent = 0, favorites = 0
    var kinds: [DeviceKind: Int] = [:]
}

/// Central app state: the selected network, its device inventory and scan / port-scan activity.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Network
    var interfaces: [NetworkInterface] = []
    private(set) var interface: NetworkInterface?
    var publicIP: PublicIPInfo?
    var dnsServers: [String] = []
    private(set) var networkKey: String?

    // MARK: Scan range
    /// Saved custom ranges, edited in Settings ▸ 扫描.
    var rangePresets: [RangePreset] = Prefs.rangePresetsValue {
        didSet {
            Prefs.rangePresetsValue = rangePresets
            if let id = selectedRangeID, !rangePresets.contains(where: { $0.id == id }) { selectedRangeID = nil }
        }
    }
    /// The preset scans cover; `nil` scans the whole subnet.
    var selectedRangeID: UUID? = Prefs.selectedRangePresetID {
        didSet { Prefs.selectedRangePresetID = selectedRangeID }
    }
    var selectedRange: RangePreset? { rangePresets.first { $0.id == selectedRangeID } }

    // MARK: Devices
    @ObservationIgnored private var inventory = DeviceInventory()
    private(set) var devices: [Device] = []
    var selection: Set<String> = []
    var sidebar: SidebarItem? = .all
    var searchText = ""
    var sortOrder: [KeyPathComparator<Device>] = [KeyPathComparator(\Device.sortableIP)]
    var showInspector = true
    var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: Prefs.viewMode) ?? "") ?? .table {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: Prefs.viewMode) }
    }
    var textScale: Double = max(0.8, UserDefaults.standard.double(forKey: Prefs.textScale)) {
        didSet { UserDefaults.standard.set(textScale, forKey: Prefs.textScale) }
    }

    // MARK: Scan state
    private(set) var isScanning = false
    private(set) var isLive = false
    private(set) var progress: Double = 0
    private(set) var phase: ScanPhase?
    private(set) var lastScan: ScanSummary?
    private(set) var lastScanDate: Date?
    private(set) var sessionNewIDs: Set<String> = []

    // MARK: Port scan
    private(set) var portScanRunning = false
    private(set) var portScanProgress: Double = 0
    private(set) var portScanStatus = ""
    var showPortScanSheet = false

    // MARK: Continuous ping of the inspected device
    private(set) var pingingID: String?

    @ObservationIgnored private let engine = ScanEngine()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var portTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathChangeTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapped = false

    private init() {}

    // MARK: - Lifecycle

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        Prefs.registerDefaults()
        textScale = max(0.8, UserDefaults.standard.double(forKey: Prefs.textScale))
        // Warm the lookup tables off the main thread.
        Task.detached(priority: .utility) {
            _ = OUIDatabase.shared
            _ = PortDatabase.shared
            _ = AppleModelDatabase.shared
        }
        refreshInterfaces()
        startPathMonitor()
        refreshPublicIP()
        Task { await activateCurrentNetwork(scan: Prefs.autoScanEnabled) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.saveNow() }
        }
    }

    func refreshInterfaces() {
        interfaces = NetworkInterface.all()
        let preferred = UserDefaults.standard.string(forKey: Prefs.selectedInterface)
        interface = interfaces.first { $0.name == preferred } ?? interfaces.first
        dnsServers = SystemDNS.servers()
    }

    func selectInterface(_ name: String) {
        UserDefaults.standard.set(name, forKey: Prefs.selectedInterface)
        refreshInterfaces()
        Task { await activateCurrentNetwork(scan: true) }
    }

    /// Loads the stored inventory of the network behind the selected interface.
    func activateCurrentNetwork(scan: Bool) async {
        guard let iface = interface else {
            devices = []
            return
        }
        let key = await NetworkIdentity.key(for: iface)
        if key != networkKey {
            stopScan()
            saveNow()
            networkKey = key
            let stored = await Task.detached(priority: .userInitiated) { DeviceStore.load(key: key) }.value
            inventory = DeviceInventory(devices: stored)
            selection = []
            sessionNewIDs = []
            publish()
        }
        if scan { startScan() }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            Task { @MainActor in AppModel.shared.networkPathChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "landetector.path"))
        pathMonitor = monitor
    }

    private func networkPathChanged() {
        pathChangeTask?.cancel()
        pathChangeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let before = interface
            refreshInterfaces()
            let after = interface
            if before?.name != after?.name || before?.ipv4 != after?.ipv4 || before?.gateway != after?.gateway {
                refreshPublicIP()
                await activateCurrentNetwork(scan: after != nil)
            }
        }
    }

    func refreshPublicIP() {
        guard Prefs.lookupPublicIPEnabled else {
            publicIP = nil
            return
        }
        Task { publicIP = await PublicIPService.fetch() }
    }

    // MARK: - Scanning

    func startScan() {
        guard !isScanning, let iface = interface else { return }
        isScanning = true
        progress = 0
        phase = .discovery
        let options = Prefs.scanOptions()
        let knownBefore = Set(inventory.devices.keys)
        scanTask = Task {
            for await event in engine.scan(iface, options: options) {
                handle(event)
            }
            scanFinished(knownBefore: knownBefore)
        }
    }

    private func handle(_ event: ScanEvent) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LANDETECTOR_DEBUG"] != nil {
            switch event {
            case .progress: break
            case .neighbors(let e, let s): print("neighbors", s, e.map { "\($0.ip)=\($0.mac) fresh:\($0.isFresh)" })
            default: print(event)
            }
        }
        #endif
        switch event {
        case .progress(let p, let ph):
            progress = p
            phase = ph
        case .finished(let summary):
            lastScan = summary
            lastScanDate = Date()
            inventory.finishScan()
        default:
            break
        }
        inventory.apply(event)
        scheduleFlush()
    }

    private func scanFinished(knownBefore: Set<String>) {
        isScanning = false
        phase = nil
        progress = 1
        let created = Set(inventory.devices.keys).subtracting(knownBefore)
        let newOnline = created.compactMap { inventory.devices[$0] }.filter(\.isOnline)
        sessionNewIDs.formUnion(newOnline.map(\.id))
        // Only alert about genuinely new devices on a network we already know.
        if !knownBefore.isEmpty, !newOnline.isEmpty, Prefs.notifyEnabled {
            Notifier.notifyNewDevices(newOnline)
        }
        publish()
        scheduleSave()
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning {
            isScanning = false
            phase = nil
            inventory.finishScan(cancelled: true)
            publish()
        }
    }

    /// Switches the scan range and rescans. A running scan is abandoned without marking the devices it has not
    /// reached yet offline: the new range may not cover them.
    func selectRange(_ id: UUID?) {
        selectedRangeID = id
        guard isScanning, let running = scanTask else {
            startScan()
            return
        }
        running.cancel()
        Task {
            await running.value
            startScan()
        }
    }

    func toggleLive() {
        if isLive {
            isLive = false
            liveTask?.cancel()
            liveTask = nil
            return
        }
        isLive = true
        if Prefs.notifyEnabled { Notifier.requestAuthorization() }
        liveTask = Task {
            while isLive, !Task.isCancelled {
                if !isScanning { startScan() }
                await scanTask?.value
                let deadline = Date().addingTimeInterval(Prefs.liveIntervalSeconds)
                while Date() < deadline, isLive, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(min(10, Prefs.liveIntervalSeconds)))
                    await refreshLatency()
                }
            }
        }
    }

    func stopAll() {
        if isLive { toggleLive() }
        stopScan()
        portTask?.cancel()
    }

    /// Pings online devices between full scans so latency stays current in live mode.
    private func refreshLatency() async {
        let ips = devices.filter(\.isOnline).compactMap(\.ipv4)
        guard !ips.isEmpty, !isScanning else { return }
        let results = await LatencyProbe.ping(ips, timeout: .milliseconds(800))
        for (ip, rtt) in results { inventory.recordLatency(rtt, for: ip) }
        publish()
    }

    /// LanScan's "Clear results": forget everything except devices carrying user data.
    func clearResults() {
        stopScan()
        for d in inventory.allDevices {
            if d.customName == nil && d.notes.isEmpty && !d.isFavorite && d.customKind == nil && d.customURL == nil {
                inventory.remove(d.id)
            } else {
                inventory.update(d.id) { $0.isOnline = false }
            }
        }
        selection = []
        sessionNewIDs = []
        publish()
        scheduleSave()
    }

    func forget(_ ids: Set<String>) {
        for id in ids { inventory.remove(id) }
        selection.subtract(ids)
        publish()
        scheduleSave()
    }

    // MARK: - Publishing & persistence

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            flushScheduled = false
            publish()
        }
    }

    private func publish() {
        devices = inventory.allDevices
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let key = networkKey else { return }
            let snapshot = inventory.allDevices
            await Task.detached(priority: .utility) { DeviceStore.save(key: key, devices: snapshot) }.value
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let key = networkKey else { return }
        DeviceStore.save(key: key, devices: inventory.allDevices)
    }

    // MARK: - Derived lists

    var visibleDevices: [Device] {
        var list = devices
        if UserDefaults.standard.bool(forKey: Prefs.hideIPv6Only) { list.removeAll { $0.ipv4 == nil } }
        switch sidebar ?? .all {
        case .all: break
        case .online: list.removeAll { !$0.isOnline }
        case .offline: list.removeAll { $0.isOnline }
        case .recent: list.removeAll { !isRecent($0) }
        case .favorites: list.removeAll { !$0.isFavorite }
        case .kind(let kind): list.removeAll { $0.effectiveKind != kind }
        }
        let terms = searchText.lowercased().split(separator: " ").map(String.init)
        if !terms.isEmpty {
            list.removeAll { d in
                let text = d.searchText
                return !terms.allSatisfy { text.contains($0) }
            }
        }
        return list.sorted(using: sortOrder)
    }

    var counts: SidebarCounts {
        var c = SidebarCounts()
        let hideV6 = UserDefaults.standard.bool(forKey: Prefs.hideIPv6Only)
        for d in devices where !(hideV6 && d.ipv4 == nil) {
            c.all += 1
            if d.isOnline { c.online += 1 } else { c.offline += 1 }
            if isRecent(d) { c.recent += 1 }
            if d.isFavorite { c.favorites += 1 }
            c.kinds[d.effectiveKind, default: 0] += 1
        }
        return c
    }

    func isRecent(_ d: Device) -> Bool {
        sessionNewIDs.contains(d.id) || d.firstSeen > Date().addingTimeInterval(-24 * 3600)
    }

    var selectedDevices: [Device] { devices.filter { selection.contains($0.id) } }

    func device(_ id: String) -> Device? { inventory.devices[id] }

    // MARK: - Editing

    func edit(_ id: String, _ body: (inout Device) -> Void) {
        inventory.update(id, body)
        publish()
        scheduleSave()
    }

    func rename(_ id: String, to name: String) {
        edit(id) { $0.customName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name }
    }

    func toggleFavorite(_ ids: Set<String>) {
        let makeFavorite = ids.contains { !(inventory.devices[$0]?.isFavorite ?? false) }
        for id in ids { inventory.update(id) { $0.isFavorite = makeFavorite } }
        publish()
        scheduleSave()
    }

    // MARK: - Port scanning

    func scanPorts(_ ids: [String], preset: PortPreset, custom: String) {
        let targets = ids.compactMap { inventory.devices[$0] }.compactMap { d in d.ipv4.map { (d, $0) } }
        let ports = preset.ports(custom: custom)
        guard !targets.isEmpty, !ports.isEmpty, !portScanRunning else { return }
        portScanRunning = true
        portScanProgress = 0
        portScanStatus = "正在扫描 \(targets.count) 台设备的 \(ports.count) 个端口…"
        let worstRTT = targets.compactMap { $0.0.latency }.max()
        let options = PortScanner.Options.adaptive(portCount: ports.count * targets.count, rtt: worstRTT)
        let endpoints = targets.flatMap { _, ip in ports.map { PortTarget(ip: ip, port: $0) } }
        let ips = targets.map(\.1)
        portTask = Task {
            let open = await PortScanner.scan(endpoints, options: options, onOpen: { _ in }, onProgress: { done, total in
                Task { @MainActor in
                    let model = AppModel.shared
                    model.portScanProgress = Double(done) / Double(max(total, 1))
                }
            })
            var byIP: [IPv4Address: [UInt16]] = [:]
            for t in open { byIP[t.ip, default: []].append(t.port) }
            if !Task.isCancelled {
                for ip in ips { inventory.setOpenPorts(byIP[ip] ?? [], for: ip) }
                publish()
                // Identify services on the open ports (web page titles, SSH / FTP greetings…).
                portScanStatus = "正在识别服务…"
                let grabbable = open.filter { BannerGrabber.canGrab($0.port) }
                await withTaskGroup(of: (PortTarget, String?).self) { group in
                    var pending = grabbable[...]
                    for _ in 0..<min(8, pending.count) {
                        let t = pending.removeFirst()
                        group.addTask { (t, await BannerGrabber.grab(t.ip, port: t.port)) }
                    }
                    for await (target, banner) in group {
                        if let banner { inventory.setBanner(banner, port: target.port, for: target.ip) }
                        if let t = pending.popFirst() {
                            group.addTask { (t, await BannerGrabber.grab(t.ip, port: t.port)) }
                        }
                    }
                }
            }
            portScanRunning = false
            portScanProgress = 1
            portScanStatus = Task.isCancelled ? "已取消" : "完成：发现 \(open.count) 个开放端口"
            publish()
            scheduleSave()
        }
    }

    func cancelPortScan() {
        portTask?.cancel()
    }

    // MARK: - Continuous ping

    func togglePing(_ id: String) {
        if pingingID == id {
            pingTask?.cancel()
            pingingID = nil
            return
        }
        pingTask?.cancel()
        guard let ip = inventory.devices[id]?.ipv4 else { return }
        pingingID = id
        pingTask = Task {
            while !Task.isCancelled {
                let result = await LatencyProbe.ping([ip], timeout: .milliseconds(900))
                guard !Task.isCancelled else { break }
                if let rtt = result[ip] {
                    inventory.recordLatency(rtt, for: ip)
                    publish()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Custom names import / export

    func exportCustomNames() -> [CustomNameRecord] {
        inventory.allDevices.compactMap { d in
            guard d.customName != nil || !d.notes.isEmpty || d.customKind != nil || d.customURL != nil || d.isFavorite else {
                return nil
            }
            return CustomNameRecord(mac: d.mac?.description, ip: d.ipv4?.description, name: d.customName,
                                    notes: d.notes.isEmpty ? nil : d.notes, kind: d.customKind?.rawValue,
                                    url: d.customURL, favorite: d.isFavorite ? true : nil)
        }
    }

    /// `overwrite == false` ("soft"): keep existing values on conflict; `true` ("hard"): imported values win.
    func importCustomNames(_ records: [CustomNameRecord], overwrite: Bool) -> Int {
        var count = 0
        for r in records {
            let mac = r.mac.flatMap(MACAddress.init)
            let ip = r.ip.flatMap(IPv4Address.init)
            guard let id = inventory.ensureDevice(mac: mac, ip: mac == nil ? ip : nil) else { continue }
            inventory.update(id) { d in
                func pick(_ current: String?, _ imported: String?) -> String? {
                    overwrite ? (imported ?? current) : (current ?? imported)
                }
                d.customName = pick(d.customName, r.name)
                d.customURL = pick(d.customURL, r.url)
                if overwrite || d.notes.isEmpty { d.notes = r.notes ?? d.notes }
                if let k = r.kind.flatMap(DeviceKind.init(rawValue:)), overwrite || d.customKind == nil { d.customKind = k }
                if r.favorite == true { d.isFavorite = true }
            }
            count += 1
        }
        publish()
        scheduleSave()
        return count
    }
}
