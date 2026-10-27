import Foundation

public enum DeviceKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case router, networkDevice, computer, laptop, server, nas, phone, tablet, watch, tv, mediaPlayer,
         speaker, printer, camera, gameConsole, smartHome, iot, virtualMachine, unknown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .router: "路由器"
        case .networkDevice: "网络设备"
        case .computer: "台式电脑"
        case .laptop: "笔记本"
        case .server: "服务器"
        case .nas: "NAS 存储"
        case .phone: "手机"
        case .tablet: "平板"
        case .watch: "手表"
        case .tv: "电视"
        case .mediaPlayer: "流媒体"
        case .speaker: "音箱"
        case .printer: "打印机"
        case .camera: "摄像头"
        case .gameConsole: "游戏机"
        case .smartHome: "智能家居"
        case .iot: "IoT 设备"
        case .virtualMachine: "虚拟机"
        case .unknown: "未知"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .router: "wifi.router"
        case .networkDevice: "point.3.connected.trianglepath.dotted"
        case .computer: "desktopcomputer"
        case .laptop: "laptopcomputer"
        case .server: "server.rack"
        case .nas: "externaldrive.connected.to.line.below"
        case .phone: "iphone"
        case .tablet: "ipad.landscape"
        case .watch: "applewatch"
        case .tv: "tv"
        case .mediaPlayer: "appletv"
        case .speaker: "hifispeaker"
        case .printer: "printer"
        case .camera: "web.camera"
        case .gameConsole: "gamecontroller"
        case .smartHome: "house"
        case .iot: "sensor"
        case .virtualMachine: "shippingbox"
        case .unknown: "questionmark.circle"
        }
    }

    /// Display order in the sidebar.
    public var sortOrder: Int { DeviceKind.allCases.firstIndex(of: self) ?? 0 }
}

/// A device on the local network, merged from all discovery sources.
public struct Device: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var mac: MACAddress?
    public var ipv4: IPv4Address?
    public var ipv6: [IPv6Address]

    public var vendor: String?
    public var vendorFull: String?
    public var dnsName: String?
    public var mdnsName: String?
    public var netbiosName: String?
    public var netbiosGroup: String?
    public var upnp: UPnPInfo?
    public var services: [BonjourService]
    public var openPorts: [UInt16]
    public var portsScannedAt: Date?
    /// HTTP titles / protocol greetings per open port.
    public var banners: [UInt16: String]

    // Identification (derived by DeviceClassifier).
    public var kind: DeviceKind
    public var model: String?
    public var manufacturer: String?
    public var osName: String?
    public var friendlyName: String?

    // User data.
    public var customName: String?
    public var customKind: DeviceKind?
    public var notes: String
    public var customURL: String?
    public var isFavorite: Bool
    /// Notify when a completed scan finds this device going online or offline.
    public var isWatched: Bool

    // Status.
    public var firstSeen: Date
    public var lastSeen: Date
    public var isOnline: Bool
    public var latency: Double?
    public var latencyHistory: [Double]
    /// Online / offline verdicts of completed scans, oldest first.
    public var presence: [PresenceSample]
    public var isGateway: Bool
    public var isCurrentDevice: Bool

    public init(id: String, mac: MACAddress? = nil, ipv4: IPv4Address? = nil, now: Date = Date()) {
        self.id = id
        self.mac = mac
        self.ipv4 = ipv4
        ipv6 = []
        services = []
        openPorts = []
        banners = [:]
        kind = .unknown
        notes = ""
        isFavorite = false
        isWatched = false
        firstSeen = now
        lastSeen = now
        isOnline = false
        latencyHistory = []
        presence = []
        isGateway = false
        isCurrentDevice = false
    }

    public static func key(for mac: MACAddress) -> String { "mac:\(mac)" }
    public static func key(for ip: IPv4Address) -> String { "ip:\(ip)" }

    // MARK: Derived

    public var effectiveKind: DeviceKind { customKind ?? kind }

    public var ipv6LinkLocal: [IPv6Address] { ipv6.filter(\.isLinkLocal) }
    public var ipv6Routable: [IPv6Address] { ipv6.filter { !$0.isLinkLocal } }
    public var hasPrivateMAC: Bool { mac?.isLocallyAdministered ?? false }

    /// Best name for display, most specific first.
    public var displayName: String {
        if let name = customName?.nilIfBlank { return name }
        if let name = friendlyName?.nilIfBlank { return name }
        if let name = mdnsName.map(Self.stripLocal)?.nilIfBlank { return name }
        if let name = netbiosName?.nilIfBlank { return name }
        if let name = dnsName.map(Self.shortDNS)?.nilIfBlank { return name }
        if let model { return model }
        if isGateway { return "网关" }
        if let vendor { return "\(vendor) 设备" }
        return ipv4?.description ?? ipv6.first?.description ?? "未知设备"
    }

    /// Secondary line: model or vendor.
    public var subtitle: String {
        if let model, displayName != model { return model }
        if let vendor { return vendor }
        if hasPrivateMAC { return "私有 MAC 地址" }
        return effectiveKind.title
    }

    /// The host name LanScan would show in its "Hostname" column.
    public var hostname: String? {
        mdnsName.map(Self.stripLocal) ?? netbiosName ?? dnsName.map(Self.shortDNS)
    }

    public var sortableIP: UInt64 { ipv4.map { UInt64($0.value) } ?? UInt64.max }

    public var openPortsText: String { openPorts.map(String.init).joined(separator: ", ") }

    static func stripLocal(_ name: String) -> String {
        var s = name.trimmingDot
        if s.lowercased().hasSuffix(".local") { s = String(s.dropLast(6)) }
        return s
    }

    static func shortDNS(_ name: String) -> String {
        let s = name.trimmingDot
        for suffix in [".lan", ".home", ".localdomain", ".local", ".home.arpa", ".router", ".domain"]
        where s.lowercased().hasSuffix(suffix) {
            return String(s.dropLast(suffix.count))
        }
        return s
    }

    /// Text used by the search field.
    public var searchText: String {
        var parts: [String] = [displayName, subtitle, effectiveKind.title, notes]
        parts += [ipv4?.description, mac?.description, vendorFull, dnsName, mdnsName, netbiosName, netbiosGroup,
                  model, manufacturer, osName, upnp?.friendlyName, upnp?.modelName].compactMap { $0 }
        parts += ipv6.map(\.description)
        parts += services.map { "\($0.name) \($0.typeDescription)" }
        parts += openPorts.map { String($0) }
        parts += banners.values
        return parts.joined(separator: " ").lowercased()
    }

    // MARK: Codable (tolerant of missing keys so stored inventories survive schema changes)

    enum CodingKeys: String, CodingKey {
        case id, mac, ipv4, ipv6, vendor, vendorFull, dnsName, mdnsName, netbiosName, netbiosGroup, upnp, services,
             openPorts, portsScannedAt, banners, kind, model, manufacturer, osName, friendlyName, customName, customKind, notes,
             customURL, isFavorite, isWatched, firstSeen, lastSeen, latency, latencyHistory, presence, isGateway, isCurrentDevice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mac = try c.decodeIfPresent(MACAddress.self, forKey: .mac)
        ipv4 = try c.decodeIfPresent(IPv4Address.self, forKey: .ipv4)
        ipv6 = (try? c.decodeIfPresent([IPv6Address].self, forKey: .ipv6)) ?? []
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        vendorFull = try c.decodeIfPresent(String.self, forKey: .vendorFull)
        dnsName = try c.decodeIfPresent(String.self, forKey: .dnsName)
        mdnsName = try c.decodeIfPresent(String.self, forKey: .mdnsName)
        netbiosName = try c.decodeIfPresent(String.self, forKey: .netbiosName)
        netbiosGroup = try c.decodeIfPresent(String.self, forKey: .netbiosGroup)
        upnp = try? c.decodeIfPresent(UPnPInfo.self, forKey: .upnp)
        services = (try? c.decodeIfPresent([BonjourService].self, forKey: .services)) ?? []
        openPorts = (try? c.decodeIfPresent([UInt16].self, forKey: .openPorts)) ?? []
        portsScannedAt = try c.decodeIfPresent(Date.self, forKey: .portsScannedAt)
        banners = (try? c.decodeIfPresent([UInt16: String].self, forKey: .banners)) ?? [:]
        kind = (try? c.decodeIfPresent(DeviceKind.self, forKey: .kind)) ?? .unknown
        model = try c.decodeIfPresent(String.self, forKey: .model)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        osName = try c.decodeIfPresent(String.self, forKey: .osName)
        friendlyName = try c.decodeIfPresent(String.self, forKey: .friendlyName)
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        customKind = try? c.decodeIfPresent(DeviceKind.self, forKey: .customKind)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        customURL = try c.decodeIfPresent(String.self, forKey: .customURL)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isWatched = try c.decodeIfPresent(Bool.self, forKey: .isWatched) ?? false
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? Date()
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? firstSeen
        latency = try c.decodeIfPresent(Double.self, forKey: .latency)
        latencyHistory = (try? c.decodeIfPresent([Double].self, forKey: .latencyHistory)) ?? []
        presence = (try? c.decodeIfPresent([PresenceSample].self, forKey: .presence)) ?? []
        isGateway = try c.decodeIfPresent(Bool.self, forKey: .isGateway) ?? false
        isCurrentDevice = try c.decodeIfPresent(Bool.self, forKey: .isCurrentDevice) ?? false
        isOnline = false
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
