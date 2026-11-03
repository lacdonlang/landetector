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

/// A change worth showing under "Recent Activity" in the network overview.
struct DeviceEvent: Identifiable {
    enum Kind { case joined, online, offline }
    let deviceID: String
    let kind: Kind
    let date: Date

    var id: String { "\(deviceID)|\(kind)|\(date.timeIntervalSince1970)" }
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
    /// Set while the list shows the store of a range behind a router (its subnet, e.g. `192.168.77.0/24`).
    private(set) var shownRemoteSubnet: String?

    // MARK: Scan range
    /// Saved custom ranges, edited in Settings ▸ Scan.
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
    /// The selected range when it lies outside this Mac's subnet, behind a router. Nothing link-local (MAC, Bonjour,
    /// IPv6) reaches this Mac from there, so its devices live in that network's own store.
    var remoteRange: IPv4Range? {
        guard let iface = interface, let range = selectedRange?.ipv4Range, !range.overlaps(iface.subnet) else { return nil }
        return range
    }

    // MARK: Devices
    @ObservationIgnored private var inventory = DeviceInventory()
    private(set) var devices: [Device] = [] {
        didSet { listRevision &+= 1 }
    }
    var selection: Set<String> = []
    var sidebar: SidebarItem? = .all
    var searchText = ""
    var sortOrder: [KeyPathComparator<Device>] = [KeyPathComparator(\Device.sortableIP)]
    var showInspector = true
    /// Visible columns, order and widths of the device table; persisted so the View ▸ Columns menu can change them.
    var columnCustomization: TableColumnCustomization<Device> = AppModel.loadColumns() {
        didSet { AppModel.saveColumns(columnCustomization) }
    }
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
    /// When LanDetector first mapped this network; devices found in that first pass are not "new".
    private(set) var networkBaseline: Date?
    /// Set by the list (Return key, context menu, Device menu) to make the inspector start renaming.
    var renameRequestID: String?

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
    /// Completed scans since this network was loaded; the first one only re-establishes who is online.
    @ObservationIgnored private var completedScans = 0
    /// Stored with the inventory so the network can be recognised again (see `NetworkMatcher`).
    @ObservationIgnored private var networkSubnet: String?
    @ObservationIgnored private var knownGatewayMACs: Set<String> = []
    /// The store of the selected interface's network; `networkKey` differs while a remote range is shown.
    @ObservationIgnored private var localNetworkKey: String?
    /// Bumped whenever another store is loaded, so a scan still running for the previous one is ignored.
    @ObservationIgnored private var storeGeneration = 0
    /// Routers on this LAN that may know names the system resolver does not (see `UnicastDNS`).
    @ObservationIgnored private var lanDNSServers: [IPv4Address] = []
    /// Bumped with every `devices` update. The list, the window subtitle and the sidebar read the derived lists on
    /// every render, so they are cached per revision.
    private var listRevision = 0
    @ObservationIgnored private var visibleCache: (key: ListKey, devices: [Device])?
    @ObservationIgnored private var countsCache: (revision: Int, hideIPv6Only: Bool, counts: SidebarCounts)?

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

    /// Loads the stored inventory of the network behind the selected interface – or, when the selected range lies
    /// behind a router, the store of that network.
    func activateCurrentNetwork(scan: Bool) async {
        guard let iface = interface else {
            devices = []
            return
        }
        // Flush the current network first, so a merge of stores sees its latest state.
        saveNow()
        if let resolution = await NetworkIdentity.resolve(for: iface, currentKey: localNetworkKey) {
            stopScan()
            localNetworkKey = resolution.key
            lanDNSServers = Self.dnsCandidates(in: resolution.devices, subnet: iface.subnet)
            if remoteRange == nil {
                show(key: resolution.key, subnet: resolution.subnet, gatewayMACs: resolution.gatewayMACs,
                     devices: NetworkMatcher.removingRemoteLeftovers(resolution.devices, subnet: iface.subnet),
                     remoteSubnet: nil)
            }
        }
        await syncRangeStore()
        if scan { startScan() }
    }

    /// Loads the store the scan range belongs to: this network's, or for a range behind a router the store of that
    /// network – its devices as recorded while this Mac was connected to it, which a scan from here can only ping.
    private func syncRangeStore() async {
        guard let iface = interface, shownRemoteSubnet != remoteRange?.coveringSubnet else { return }
        stopScan()
        saveNow()
        if let range = remoteRange {
            let store = await NetworkIdentity.resolve(remote: range, from: iface)
            show(key: store.key, subnet: store.subnet, gatewayMACs: store.gatewayMACs, devices: store.devices,
                 remoteSubnet: range.coveringSubnet)
        } else if let key = localNetworkKey {
            let stored = await Task.detached(priority: .userInitiated) { DeviceStore.load(key: key) }.value
            show(key: key, subnet: NetworkMatcher.subnetKey(iface.ipv4, netmask: iface.netmask),
                 gatewayMACs: Set(stored?.gatewayMACs ?? []),
                 devices: NetworkMatcher.removingRemoteLeftovers(stored?.devices ?? [], subnet: iface.subnet),
                 remoteSubnet: nil)
        }
    }

    private func show(key: String, subnet: String?, gatewayMACs: Set<String>, devices: [Device], remoteSubnet: String?) {
        storeGeneration += 1
        networkKey = key
        shownRemoteSubnet = remoteSubnet
        networkSubnet = subnet
        knownGatewayMACs = gatewayMACs
        inventory = DeviceInventory(devices: devices)
        // Assigning even an unchanged selection makes the table push it to AppKit again.
        if !selection.isEmpty { selection = [] }
        sessionNewIDs = []
        completedScans = 0
        lastScan = nil
        lastScanDate = nil
        publish()
    }

    /// Devices on this LAN that probably answer DNS queries: port 53 seen open, or a router.
    private static func dnsCandidates(in devices: [Device], subnet: IPv4Range) -> [IPv4Address] {
        devices.filter { $0.openPorts.contains(53) || $0.effectiveKind == .router }.compactMap(\.ipv4).filter(subnet.contains)
    }

    /// Where to ask for names the system resolver lacks: routers on this LAN, the gateway, and for a range behind a
    /// router its first address (usually that router).
    private func reverseDNSServers(for iface: NetworkInterface) -> [IPv4Address] {
        let system = Set(dnsServers.compactMap(IPv4Address.init))
        var candidates = lanDNSServers + [iface.gateway].compactMap { $0 }
        if let range = remoteRange, let first = IPv4Range(string: range.coveringSubnet)?.lower { candidates.append(first) }
        var seen = system
        return Array(candidates.filter { seen.insert($0).inserted }.prefix(4))
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
        // The range may have moved behind a router (or back) since the store was loaded, e.g. edited in Settings.
        if shownRemoteSubnet != remoteRange?.coveringSubnet {
            Task {
                await syncRangeStore()
                if shownRemoteSubnet == remoteRange?.coveringSubnet { startScan() }
            }
            return
        }
        isScanning = true
        progress = 0
        phase = .discovery
        var options = Prefs.scanOptions()
        options.extraDNSServers = reverseDNSServers(for: iface)
        let knownBefore = Set(inventory.devices.keys)
        let onlineBefore = inventory.devices.mapValues(\.isOnline)
        let generation = storeGeneration
        scanTask = Task {
            for await event in engine.scan(iface, options: options) {
                guard generation == storeGeneration else { break }
                handle(event)
            }
            scanFinished(generation: generation, knownBefore: knownBefore, onlineBefore: onlineBefore,
                         cancelled: Task.isCancelled)
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
        // Progress alone leaves the list as it is.
        if !inventory.apply(event).isEmpty { scheduleFlush() }
    }

    private func scanFinished(generation: Int, knownBefore: Set<String>, onlineBefore: [String: Bool], cancelled: Bool) {
        isScanning = false
        phase = nil
        progress = 1
        // Another store was loaded meanwhile; nothing below applies to it.
        guard generation == storeGeneration else { return }
        // Watched devices that went online or offline. Skipped for the first scan after loading a network
        // (stored devices start out offline) and for scans that were cut short.
        if !cancelled, completedScans > 0 {
            let changed = inventory.devices.values.filter { d in
                d.isWatched && onlineBefore[d.id].map { $0 != d.isOnline } == true
            }
            if !changed.isEmpty { Notifier.notifyPresenceChanges(Array(changed)) }
        }
        if !cancelled {
            if completedScans == 0, shownRemoteSubnet == nil { reconcileStores() }
            completedScans += 1
            if shownRemoteSubnet == nil, let iface = interface {
                lanDNSServers = Self.dnsCandidates(in: inventory.allDevices, subnet: iface.subnet)
            }
        }
        let created = Set(inventory.devices.keys).subtracting(knownBefore)
        let newOnline = created.compactMap { inventory.devices[$0] }.filter(\.isOnline)
        // The first scan of a network finds everything – that is not news. Only devices that join a network we
        // already know are highlighted (and announced).
        if !knownBefore.isEmpty, !newOnline.isEmpty {
            sessionNewIDs.formUnion(newOnline.map(\.id))
            if Prefs.notifyEnabled { Notifier.notifyNewDevices(newOnline) }
        }
        publish()
        scheduleSave()
    }

    /// A stopped scan says nothing about the devices it had not reached yet, so they keep their last state.
    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning {
            isScanning = false
            phase = nil
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
            if !d.hasUserData {
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
        networkBaseline = devices.lazy.map(\.firstSeen).min()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let key = networkKey else { return }
            let snapshot = inventory.allDevices
            let subnet = networkSubnet
            let gateways = currentGatewayMACs()
            await Task.detached(priority: .utility) {
                DeviceStore.save(key: key, devices: snapshot, subnet: subnet, gatewayMACs: gateways)
            }.value
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let key = networkKey else { return }
        DeviceStore.save(key: key, devices: inventory.allDevices, subnet: networkSubnet, gatewayMACs: currentGatewayMACs())
    }

    /// Folds in other stores of this network that only the full device list of a scan reveals as the same LAN
    /// (the gateway MAC changed, or the ARP cache was nearly empty at launch).
    private func reconcileStores() {
        guard let key = networkKey, let iface = interface, let subnet = networkSubnet else { return }
        let visible = Set(inventory.allDevices.filter(\.isOnline).compactMap(\.mac))
        let gatewayMAC = inventory.allDevices.first(where: \.isGateway)?.mac
        Task {
            let stray = await NetworkIdentity.strayStores(of: key, interface: iface, subnet: subnet, visible: visible,
                                                          gatewayMAC: gatewayMAC)
            guard !stray.keys.isEmpty, networkKey == key else { return }
            inventory.absorb(stray.devices)
            knownGatewayMACs.formUnion(stray.gatewayMACs)
            publish()
            saveNow()
        }
    }

    /// Gateway MACs this network has used, including the one the latest scan found.
    private func currentGatewayMACs() -> Set<String> {
        knownGatewayMACs.union(inventory.allDevices.filter(\.isGateway).compactMap { $0.mac?.description })
    }

    // MARK: - Derived lists

    private struct ListKey: Equatable {
        var revision: Int
        var hideIPv6Only: Bool
        var sidebar: SidebarItem?
        var search: String
        var sortOrder: [KeyPathComparator<Device>]
    }

    var visibleDevices: [Device] {
        let key = ListKey(revision: listRevision, hideIPv6Only: Prefs.hideIPv6OnlyEnabled, sidebar: sidebar,
                          search: searchText, sortOrder: sortOrder)
        if let cache = visibleCache, cache.key == key { return cache.devices }
        var list = devices
        if key.hideIPv6Only { list.removeAll { $0.ipv4 == nil } }
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
        list.sort(using: sortOrder)
        visibleCache = (key, list)
        return list
    }

    var counts: SidebarCounts {
        let hideIPv6Only = Prefs.hideIPv6OnlyEnabled
        if let cache = countsCache, cache.revision == listRevision, cache.hideIPv6Only == hideIPv6Only {
            return cache.counts
        }
        var c = SidebarCounts()
        for d in devices where !(hideIPv6Only && d.ipv4 == nil) {
            c.all += 1
            if d.isOnline { c.online += 1 } else { c.offline += 1 }
            if isRecent(d) { c.recent += 1 }
            if d.isFavorite { c.favorites += 1 }
            c.kinds[d.effectiveKind, default: 0] += 1
        }
        countsCache = (listRevision, hideIPv6Only, c)
        return c
    }

    /// Joined in the last 24 hours, but after the network's first scan.
    func isRecent(_ d: Device) -> Bool {
        if sessionNewIDs.contains(d.id) { return true }
        guard d.firstSeen > Date().addingTimeInterval(-24 * 3600), let baseline = networkBaseline else { return false }
        return d.firstSeen > baseline.addingTimeInterval(15 * 60)
    }

    /// Window title: the group of devices the list shows.
    var listTitle: String {
        switch sidebar ?? .all {
        case .all: String(localized: "All Devices")
        case .online: String(localized: "Online Devices")
        case .offline: String(localized: "Offline Devices")
        case .recent: String(localized: "New Devices")
        case .favorites: String(localized: "Favorites")
        case .kind(let kind): kind.title
        }
    }

    /// Window subtitle: what the list contains right now (or the scan's progress / the search result).
    var listSummary: String {
        guard interface != nil else { return "" }
        if isScanning { return String(localized: "Scanning \(Int(progress * 100))%") }
        let list = visibleDevices
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "\(list.count) found") }
        let online = list.filter(\.isOnline).count
        var text = online == list.count
            ? String(localized: "\(list.count) online")
            : String(localized: "\(list.count) total · \(online) online")
        if isLive { text += " · " + String(localized: "Live monitoring") }
        if let range = selectedRange { text += " · " + String(localized: "Range: \(range.title)") }
        return text
    }

    func requestRename(_ id: String) {
        selection = [id]
        showInspector = true
        renameRequestID = id
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

    /// Turns online / offline notifications on for all `ids` (or off, when they are all on already).
    func toggleWatch(_ ids: Set<String>) {
        let watch = ids.contains { !(inventory.devices[$0]?.isWatched ?? false) }
        for id in ids { inventory.update(id) { $0.isWatched = watch } }
        if watch { Notifier.requestAuthorization() }
        publish()
        scheduleSave()
    }

    /// Newest first: devices that joined after the network's first scan, and the latest online / offline change
    /// that completed scans recorded for each device.
    func recentEvents(limit: Int = 8) -> [DeviceEvent] {
        var events: [DeviceEvent] = []
        for d in devices {
            var latest: DeviceEvent?
            if isRecent(d) { latest = DeviceEvent(deviceID: d.id, kind: .joined, date: d.firstSeen) }
            if let change = d.lastPresenceChange {
                // A device goes offline some time after it was last seen; the first scan that missed it may come
                // much later (the app was not running), so date the change by when it was last online.
                let date = change.online ? change.date : min(change.date, d.lastSeen)
                if date > (latest?.date ?? .distantPast) {
                    latest = DeviceEvent(deviceID: d.id, kind: change.online ? .online : .offline, date: date)
                }
            }
            if let latest { events.append(latest) }
        }
        return Array(events.sorted { $0.date > $1.date }.prefix(limit))
    }

    // MARK: - Table columns

    func isColumnVisible(_ column: DeviceColumn) -> Bool {
        switch columnCustomization[visibility: column.id] {
        case .visible: true
        case .hidden: false
        default: column.visibleByDefault
        }
    }

    func setColumn(_ column: DeviceColumn, visible: Bool) {
        columnCustomization[visibility: column.id] = visible ? .visible : .hidden
    }

    func resetColumns() {
        columnCustomization = TableColumnCustomization()
    }

    private static let columnsKey = "deviceTableColumns.v3"

    private static func loadColumns() -> TableColumnCustomization<Device> {
        guard let data = UserDefaults.standard.data(forKey: columnsKey),
              let stored = try? JSONDecoder().decode(TableColumnCustomization<Device>.self, from: data) else {
            return TableColumnCustomization()
        }
        return stored
    }

    private static func saveColumns(_ columns: TableColumnCustomization<Device>) {
        UserDefaults.standard.set(try? JSONEncoder().encode(columns), forKey: columnsKey)
    }

    // MARK: - Port scanning

    func scanPorts(_ ids: [String], preset: PortPreset, custom: String) {
        let targets = ids.compactMap { inventory.devices[$0] }.compactMap { d in d.ipv4.map { (d, $0) } }
        let ports = preset.ports(custom: custom)
        guard !targets.isEmpty, !ports.isEmpty, !portScanRunning else { return }
        portScanRunning = true
        portScanProgress = 0
        portScanStatus = targets.count == 1
            ? String(localized: "Scanning \(ports.count) ports…")
            : String(localized: "Scanning \(ports.count) ports on \(targets.count) devices…")
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
                portScanStatus = String(localized: "Identifying services…")
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
            portScanStatus = Task.isCancelled
                ? String(localized: "Canceled")
                : String(localized: "Finished. Open ports: \(open.count)")
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
            guard d.hasUserData else { return nil }
            return CustomNameRecord(mac: d.mac?.description, ip: d.ipv4?.description, name: d.customName,
                                    notes: d.notes.isEmpty ? nil : d.notes, kind: d.customKind?.rawValue,
                                    url: d.customURL, favorite: d.isFavorite ? true : nil,
                                    watched: d.isWatched ? true : nil)
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
                if r.watched == true { d.isWatched = true }
            }
            count += 1
        }
        publish()
        scheduleSave()
        return count
    }
}

#if DEBUG
extension AppModel {
    /// Shows a made-up network for screenshots (see `DemoNetwork`): nothing is scanned, resolved or saved.
    func showDemo(_ demo: DemoNetwork) {
        bootstrapped = true
        Prefs.registerDefaults()
        interfaces = [demo.interface]
        interface = demo.interface
        dnsServers = demo.dnsServers
        publicIP = demo.publicIP
        networkKey = nil
        inventory = DeviceInventory(devices: demo.devices)
        lastScan = demo.lastScan
        lastScanDate = demo.lastScanDate
        completedScans = 1
        publish()
    }
}
#endif
