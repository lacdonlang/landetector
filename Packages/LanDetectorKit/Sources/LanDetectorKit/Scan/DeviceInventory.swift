import Foundation

public struct ScanContext: Sendable, Hashable {
    public let interface: NetworkInterface
    public let range: IPv4Range
    public let startedAt: Date

    /// `false` for a range behind a router: this Mac and its gateway are not part of it, and nothing link-local
    /// (ARP, NDP, multicast discovery) reaches this Mac from there.
    public var isLocal: Bool { range.overlaps(interface.subnet) }

    /// Addresses a scan reports on: the range, plus this Mac and its gateway when the range is local.
    public func covers(_ ip: IPv4Address) -> Bool {
        range.contains(ip) || (isLocal && (ip == interface.ipv4 || ip == interface.gateway))
    }
}

public enum ScanPhase: String, Sendable {
    case discovery = "发现设备"
    case enrichment = "识别设备"
    case finishing = "完成"
}

public struct ScanSummary: Sendable, Hashable {
    public var duration: TimeInterval
    public var hostsProbed: Int
    public var neighborSource: ARPTable.Source
}

public enum ScanEvent: Sendable {
    case started(ScanContext)
    case progress(Double, ScanPhase)
    case alive(IPv4Address, rtt: Double)
    case neighbors([ARPEntry], source: ARPTable.Source)
    case ipv6Alive(IPv6Address, rtt: Double)
    case ndp([NDPEntry])
    case dnsName(IPv4Address, String)
    case mdns(IPv4Address, MDNSHostInfo)
    case netbios(IPv4Address, NetBIOSInfo)
    case ssdp(IPv4Address, SSDPResponse)
    case upnp(IPv4Address, UPnPInfo)
    case finished(ScanSummary)
}

/// Merges scan events into a set of devices keyed by MAC (or IP while the MAC is unknown).
public struct DeviceInventory: Sendable {
    public private(set) var devices: [String: Device] = [:]
    private var byIP: [IPv4Address: String] = [:]
    private var byMAC: [MACAddress: String] = [:]
    private var byIPv6: [IPv6Address: String] = [:]
    private var pendingIPv6: [IPv6Address: Double] = [:]
    public private(set) var seenThisScan: Set<String> = []
    public private(set) var context: ScanContext?
    private var presencePending = false

    public init(devices: [Device] = []) {
        for d in devices { insert(d) }
    }

    public var allDevices: [Device] { Array(devices.values) }

    public func device(forIP ip: IPv4Address) -> Device? { byIP[ip].flatMap { devices[$0] } }

    // MARK: - Scan lifecycle

    public mutating func beginScan(_ context: ScanContext) {
        self.context = context
        seenThisScan = []
        pendingIPv6 = [:]
        presencePending = true
        for id in devices.keys { refreshIdentity(id) }
    }

    /// Marks devices in the scanned range that did not answer as offline. A completed scan also adds a presence
    /// sample to every device it could have seen; a cancelled one leaves the history alone.
    @discardableResult
    public mutating func finishScan(now: Date = Date(), cancelled: Bool = false) -> Set<String> {
        guard let context else { return [] }
        let recordsPresence = presencePending && !cancelled
        presencePending = false
        var changed: Set<String> = []
        for (id, d) in devices {
            let seen = seenThisScan.contains(id)
            let inRange = d.ipv4.map(context.range.contains) ?? true
            if d.isOnline, !seen, inRange {
                devices[id]?.isOnline = false
                changed.insert(id)
            }
            if recordsPresence, seen || inRange { devices[id]?.recordPresence(online: seen, at: now) }
        }
        return changed
    }

    // MARK: - Events

    @discardableResult
    public mutating func apply(_ event: ScanEvent, now: Date = Date()) -> Set<String> {
        var changed: Set<String> = []
        switch event {
        case .started(let ctx):
            beginScan(ctx)
        case .alive(let ip, let rtt):
            guard accepts(ip) else { break }
            let id = resolve(ip, now: now)
            markSeen(id, now: now)
            devices[id]?.latency = rtt
            devices[id]?.latencyHistory.append(rtt)
            if let n = devices[id]?.latencyHistory.count, n > 60 { devices[id]?.latencyHistory.removeFirst(n - 60) }
            changed.insert(id)
        case .neighbors(let entries, _):
            for entry in entries where entry.isFresh && accepts(entry.ip) {
                let id = attach(entry.mac, to: entry.ip, now: now)
                markSeen(id, now: now)
                changed.insert(id)
            }
        case .ipv6Alive(let ip, let rtt):
            if let id = byIPv6[ip], devices[id] != nil {
                markSeen(id, now: now)
                changed.insert(id)
            } else if let mac = ip.eui64MAC, let id = byMAC[mac], devices[id] != nil {
                addIPv6(ip, to: id)
                markSeen(id, now: now)
                changed.insert(id)
            } else {
                pendingIPv6[ip] = rtt
            }
        case .ndp(let entries):
            for entry in entries {
                if let id = byMAC[entry.mac] {
                    addIPv6(entry.ip, to: id)
                    if pendingIPv6.removeValue(forKey: entry.ip) != nil { markSeen(id, now: now) }
                    changed.insert(id)
                } else if pendingIPv6.removeValue(forKey: entry.ip) != nil {
                    // IPv6-only device (no IPv4 neighbour entry).
                    let id = Device.key(for: entry.mac)
                    insert(Device(id: id, mac: entry.mac, now: now))
                    addIPv6(entry.ip, to: id)
                    markSeen(id, now: now)
                    changed.insert(id)
                }
            }
        case .dnsName(let ip, let name):
            guard accepts(ip) else { break }
            let id = resolve(ip, now: now)
            devices[id]?.dnsName = name
            changed.insert(id)
        case .mdns(let ip, let info):
            guard accepts(ip) else { break }
            let id = resolve(ip, now: now)
            markSeen(id, now: now)
            if let host = info.hostname { devices[id]?.mdnsName = host }
            if !info.services.isEmpty {
                let merged = mergeServices(devices[id]?.services ?? [], info.services)
                devices[id]?.services = merged
            }
            for v6 in info.ipv6 { addIPv6(v6, to: id) }
            changed.insert(id)
        case .netbios(let ip, let info):
            guard accepts(ip) else { break }
            var id = resolve(ip, now: now)
            if let mac = info.mac, devices[id]?.mac == nil { id = attach(mac, to: ip, now: now) }
            markSeen(id, now: now)
            devices[id]?.netbiosName = info.name
            devices[id]?.netbiosGroup = info.group
            changed.insert(id)
        case .ssdp(let ip, let response):
            guard accepts(ip) else { break }
            let id = resolve(ip, now: now)
            markSeen(id, now: now)
            if let server = response.server {
                var upnp = devices[id]?.upnp ?? UPnPInfo()
                upnp.server = server
                devices[id]?.upnp = upnp
            }
            changed.insert(id)
        case .upnp(let ip, let info):
            guard accepts(ip) else { break }
            let id = resolve(ip, now: now)
            var merged = info
            merged.server = devices[id]?.upnp?.server ?? info.server
            devices[id]?.upnp = merged
            changed.insert(id)
        case .progress, .finished:
            break
        }
        for id in changed { refreshIdentity(id) }
        return changed
    }

    // MARK: - User edits

    public mutating func update(_ id: String, _ body: (inout Device) -> Void) {
        guard var d = devices[id] else { return }
        body(&d)
        devices[id] = d
        refreshIdentity(id)
    }

    /// Finds (or creates an offline record for) the device with this MAC / IP – used by imports.
    public mutating func ensureDevice(mac: MACAddress?, ip: IPv4Address?, now: Date = Date()) -> String? {
        if let mac, let id = byMAC[mac], devices[id] != nil { return id }
        if mac == nil, let ip, let id = byIP[ip], devices[id] != nil { return id }
        guard mac != nil || ip != nil else { return nil }
        let id = mac.map(Device.key(for:)) ?? Device.key(for: ip!)
        insert(Device(id: id, mac: mac, ipv4: ip, now: now))
        refreshIdentity(id)
        return id
    }

    /// Records a latency sample from a ping between full scans.
    public mutating func recordLatency(_ rtt: Double, for ip: IPv4Address, now: Date = Date()) {
        guard let id = byIP[ip], devices[id] != nil else { return }
        devices[id]?.latency = rtt
        devices[id]?.latencyHistory.append(rtt)
        if let n = devices[id]?.latencyHistory.count, n > 60 { devices[id]?.latencyHistory.removeFirst(n - 60) }
        devices[id]?.lastSeen = now
        devices[id]?.isOnline = true
    }

    /// Folds in devices from another store of the same network. Current values win; history is combined.
    public mutating func absorb(_ others: [Device]) {
        for incoming in others {
            if let existing = devices[incoming.id] {
                devices[incoming.id] = Self.merged(incoming, into: existing, preferSourceLatency: false)
            } else {
                var d = incoming
                d.isOnline = false
                devices[d.id] = d
                // Historical records never take an address away from a current device.
                if let mac = d.mac, byMAC[mac] == nil { byMAC[mac] = d.id }
                if let ip = d.ipv4, byIP[ip] == nil { byIP[ip] = d.id }
            }
            for v6 in devices[incoming.id]?.ipv6 ?? [] where byIPv6[v6] == nil { byIPv6[v6] = incoming.id }
            refreshIdentity(incoming.id)
        }
    }

    public mutating func remove(_ id: String) {
        guard let d = devices.removeValue(forKey: id) else { return }
        if let ip = d.ipv4, byIP[ip] == id { byIP[ip] = nil }
        if let mac = d.mac, byMAC[mac] == id { byMAC[mac] = nil }
        for v6 in d.ipv6 where byIPv6[v6] == id { byIPv6[v6] = nil }
    }

    public mutating func setOpenPorts(_ ports: [UInt16], for ip: IPv4Address, now: Date = Date()) {
        guard let id = byIP[ip] else { return }
        devices[id]?.openPorts = ports
        devices[id]?.portsScannedAt = now
        let kept = devices[id]?.banners.filter { ports.contains($0.key) } ?? [:]
        devices[id]?.banners = kept
        refreshIdentity(id)
    }

    public mutating func setBanner(_ banner: String, port: UInt16, for ip: IPv4Address) {
        guard let id = byIP[ip] else { return }
        devices[id]?.banners[port] = banner
        refreshIdentity(id)
    }

    // MARK: - Internals

    private func accepts(_ ip: IPv4Address) -> Bool { context?.covers(ip) ?? true }

    private mutating func insert(_ d: Device) {
        devices[d.id] = d
        if let ip = d.ipv4, holdsAddress(d, over: byIP[ip].flatMap { devices[$0] }) { byIP[ip] = d.id }
        if let mac = d.mac { byMAC[mac] = d.id }
        for v6 in d.ipv6 { byIPv6[v6] = d.id }
    }

    /// Several records can remember one address (DHCP churn, a replaced router, merged stores). Until a scan says
    /// otherwise the address belongs to a MAC record over a placeholder, and then to the most recently seen one.
    private func holdsAddress(_ d: Device, over current: Device?) -> Bool {
        guard let current, current.id != d.id else { return true }
        if (d.mac != nil) != (current.mac != nil) { return d.mac != nil }
        return d.lastSeen >= current.lastSeen
    }

    private mutating func markSeen(_ id: String, now: Date) {
        seenThisScan.insert(id)
        devices[id]?.isOnline = true
        devices[id]?.lastSeen = now
    }

    private mutating func addIPv6(_ ip: IPv6Address, to id: String) {
        guard !ip.isMulticast, devices[id]?.ipv6.contains(ip) == false else { return }
        devices[id]?.ipv6.append(ip)
        devices[id]?.ipv6.sort()
        byIPv6[ip] = id
    }

    /// Device currently holding `ip`, creating an IP-keyed placeholder if needed.
    private mutating func resolve(_ ip: IPv4Address, now: Date) -> String {
        if let id = byIP[ip], devices[id] != nil { return id }
        let id = Device.key(for: ip)
        if devices[id] == nil { insert(Device(id: id, ipv4: ip, now: now)) }
        byIP[ip] = id
        return id
    }

    /// Associates `mac` with `ip`, merging/upgrading placeholder records.
    private mutating func attach(_ mac: MACAddress, to ip: IPv4Address, now: Date) -> String {
        let target: String
        if let macID = byMAC[mac], devices[macID] != nil {
            target = macID
            if let ipID = byIP[ip], ipID != macID, devices[ipID]?.mac == nil {
                merge(from: ipID, into: macID)
            }
        } else if let ipID = byIP[ip], let d = devices[ipID], d.mac == nil {
            // Upgrade the IP-keyed record to a MAC-keyed one.
            var upgraded = d
            devices[ipID] = nil
            upgraded.id = Device.key(for: mac)
            upgraded.mac = mac
            if let existing = devices[upgraded.id] { upgraded = Self.merged(upgraded, into: existing) }
            insert(upgraded)
            target = upgraded.id
            for v6 in upgraded.ipv6 { byIPv6[v6] = target }
        } else {
            target = Device.key(for: mac)
            if devices[target] == nil { insert(Device(id: target, mac: mac, ipv4: ip, now: now)) }
        }
        byMAC[mac] = target
        for (v6, _) in pendingIPv6 where v6.eui64MAC == mac {
            pendingIPv6[v6] = nil
            addIPv6(v6, to: target)
        }
        if let old = devices[target]?.ipv4, old != ip, byIP[old] == target { byIP[old] = nil }
        devices[target]?.ipv4 = ip
        devices[target]?.mac = mac
        let previousHolder = byIP[ip]
        byIP[ip] = target
        // The record that used to hold this address may have been flagged as gateway / this Mac because of it.
        if let previousHolder, previousHolder != target, devices[previousHolder] != nil { refreshIdentity(previousHolder) }
        return target
    }

    private mutating func merge(from sourceID: String, into targetID: String) {
        guard let source = devices.removeValue(forKey: sourceID), let target = devices[targetID] else { return }
        if seenThisScan.remove(sourceID) != nil { seenThisScan.insert(targetID) }
        let merged = Self.merged(source, into: target)
        devices[targetID] = merged
        for v6 in merged.ipv6 { byIPv6[v6] = targetID }
    }

    /// `preferSourceLatency`: a placeholder merged into its MAC record carries the newest ping; history does not.
    static func merged(_ s: Device, into t: Device, preferSourceLatency: Bool = true) -> Device {
        var m = t
        m.dnsName = m.dnsName ?? s.dnsName
        m.mdnsName = m.mdnsName ?? s.mdnsName
        m.netbiosName = m.netbiosName ?? s.netbiosName
        m.netbiosGroup = m.netbiosGroup ?? s.netbiosGroup
        m.upnp = m.upnp ?? s.upnp
        m.services = DeviceInventory().mergeServices(m.services, s.services)
        m.openPorts = Array(Set(m.openPorts + s.openPorts)).sorted()
        m.portsScannedAt = m.portsScannedAt ?? s.portsScannedAt
        m.banners = m.banners.merging(s.banners) { a, _ in a }
        m.latency = preferSourceLatency ? (s.latency ?? m.latency) : (m.latency ?? s.latency)
        m.latencyHistory = (m.latencyHistory + s.latencyHistory).suffix(60)
        m.presence = Device.mergedPresence(m.presence, s.presence)
        m.customName = m.customName ?? s.customName
        m.customKind = m.customKind ?? s.customKind
        m.customURL = m.customURL ?? s.customURL
        if m.notes.isEmpty { m.notes = s.notes }
        m.isFavorite = m.isFavorite || s.isFavorite
        m.isWatched = m.isWatched || s.isWatched
        m.firstSeen = min(m.firstSeen, s.firstSeen)
        m.lastSeen = max(m.lastSeen, s.lastSeen)
        m.isOnline = m.isOnline || s.isOnline
        m.ipv6 = Array(Set(m.ipv6 + s.ipv6)).sorted()
        return m
    }

    private func mergeServices(_ old: [BonjourService], _ new: [BonjourService]) -> [BonjourService] {
        var byID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in new {
            if var existing = byID[s.id] {
                if s.port != 0 { existing.port = s.port }
                if !s.txt.isEmpty { existing.txt = s.txt }
                byID[s.id] = existing
            } else {
                byID[s.id] = s
            }
        }
        return byID.values.sorted { ($0.type, $0.name) < ($1.type, $1.name) }
    }

    /// Recomputes vendor, flags and identification.
    private mutating func refreshIdentity(_ id: String) {
        guard var d = devices[id] else { return }
        if let mac = d.mac, d.vendorFull == nil, let full = OUIDatabase.shared.vendor(for: mac) {
            d.vendorFull = full
            d.vendor = OUIDatabase.shortName(full)
        }
        if let iface = context?.interface {
            // Only the record currently holding an address counts – older records may remember the same one.
            let holdsIP = d.ipv4.map { byIP[$0] == id } ?? false
            d.isGateway = holdsIP && d.ipv4 == iface.gateway
            d.isCurrentDevice = (holdsIP && d.ipv4 == iface.ipv4) || (d.mac != nil && d.mac == iface.mac)
        }
        let identity = DeviceClassifier.identify(d)
        d.kind = identity.kind
        d.model = identity.model
        d.manufacturer = identity.manufacturer
        d.osName = identity.osName
        d.friendlyName = d.isCurrentDevice ? LocalMachine.hostName : identity.friendlyName
        if d != devices[id] { devices[id] = d }
    }
}
