import Darwin
import Foundation
import SystemConfiguration

/// A network interface with an IPv4 configuration that can be scanned.
public struct NetworkInterface: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, Codable {
        case wifi, ethernet, bridge, vpn, other
    }

    public var id: String { name }
    /// BSD name, e.g. `en0`.
    public let name: String
    public let index: UInt32
    /// Localised name, e.g. "Wi-Fi".
    public var displayName: String
    public var kind: Kind
    public var mac: MACAddress?
    public var ipv4: IPv4Address
    public var netmask: IPv4Address
    public var gateway: IPv4Address?
    public var ipv6: [IPv6Address]

    public init(name: String, index: UInt32, displayName: String, kind: Kind, mac: MACAddress?, ipv4: IPv4Address,
                netmask: IPv4Address, gateway: IPv4Address?, ipv6: [IPv6Address]) {
        self.name = name
        self.index = index
        self.displayName = displayName
        self.kind = kind
        self.mac = mac
        self.ipv4 = ipv4
        self.netmask = netmask
        self.gateway = gateway
        self.ipv6 = ipv6
    }

    public var prefixLength: Int { netmask.value.nonzeroBitCount }
    public var subnet: IPv4Range { .subnet(address: ipv4, netmask: netmask) }
    public var cidr: String { "\(ipv4)/\(prefixLength)" }
    public var broadcast: IPv4Address { IPv4Address(ipv4.value | ~netmask.value) }
    public var supportsARP: Bool { kind != .vpn && mac != nil }
    public var ipv6LinkLocal: IPv6Address? { ipv6.first(where: \.isLinkLocal) }
    public var ipv6Global: [IPv6Address] { ipv6.filter { $0.isGlobal || $0.isUniqueLocal } }

    /// All interfaces that are up and have a non-loopback IPv4 address, primary interface first.
    public static func all() -> [NetworkInterface] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        struct Partial {
            var ipv4: IPv4Address?
            var netmask: IPv4Address?
            var mac: MACAddress?
            var ipv6: [IPv6Address] = []
            var flags: UInt32 = 0
        }
        var partials: [String: Partial] = [:]
        var order: [String] = []

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            if partials[name] == nil { order.append(name) }
            var p = partials[name] ?? Partial()
            p.flags = ifa.ifa_flags
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                if p.ipv4 == nil {
                    p.ipv4 = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4Address($0.pointee.sin_addr) }
                    if let mask = ifa.ifa_netmask {
                        p.netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4Address($0.pointee.sin_addr) }
                    }
                }
            case AF_INET6:
                let addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { IPv6Address($0.pointee.sin6_addr) }
                p.ipv6.append(addr.withoutEmbeddedScope)
            case AF_LINK:
                p.mac = linkAddress(UnsafeRawPointer(sa))
            default:
                break
            }
            partials[name] = p
        }

        let names = SCInterfaceNames.load()
        let gateways = RoutingTable.defaultGateways()
        var result: [NetworkInterface] = []
        for name in order {
            guard let p = partials[name], let ip = p.ipv4, let mask = p.netmask else { continue }
            let flags = Int32(bitPattern: p.flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, !ip.isLinkLocal else { continue }
            let index = if_nametoindex(name)
            var kind: Kind = names.kinds[name] ?? .other
            if flags & IFF_POINTOPOINT != 0 || name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") {
                kind = .vpn
            } else if name.hasPrefix("bridge") {
                kind = .bridge
            }
            result.append(NetworkInterface(
                name: name, index: index,
                displayName: names.displayNames[name] ?? defaultDisplayName(name, kind: kind),
                kind: kind, mac: p.mac.flatMap { $0.isUsable ? $0 : nil } ?? HardwareAddress.lookup(bsdName: name),
                ipv4: ip, netmask: mask,
                gateway: gateways[index],
                ipv6: p.ipv6))
        }
        let primaryIndex = RoutingTable.primaryInterfaceIndex()
        return result.sorted { a, b in
            if (a.index == primaryIndex) != (b.index == primaryIndex) { return a.index == primaryIndex }
            if (a.kind == .vpn) != (b.kind == .vpn) { return b.kind == .vpn }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public static func primary() -> NetworkInterface? { all().first }

    private static func defaultDisplayName(_ name: String, kind: Kind) -> String {
        switch kind {
        case .wifi: "Wi-Fi"
        case .ethernet: localized("Ethernet")
        case .bridge: localized("Bridge")
        case .vpn: "VPN"
        case .other: name
        }
    }

    /// Extracts the hardware address from a `sockaddr_dl`.
    static func linkAddress(_ sa: UnsafeRawPointer) -> MACAddress? {
        let nlen = Int(sa.load(fromByteOffset: 5, as: UInt8.self))
        let alen = Int(sa.load(fromByteOffset: 6, as: UInt8.self))
        guard alen == 6 else { return nil }
        let start = sa + 8 + nlen
        return MACAddress(bytes: (0..<6).map { start.load(fromByteOffset: $0, as: UInt8.self) })
    }
}

/// Localised interface names and kinds from SystemConfiguration.
private struct SCInterfaceNames {
    var displayNames: [String: String] = [:]
    var kinds: [String: NetworkInterface.Kind] = [:]

    static func load() -> SCInterfaceNames {
        var result = SCInterfaceNames()
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return result }
        for iface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            if let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                result.displayNames[bsd] = name
            }
            guard let type = SCNetworkInterfaceGetInterfaceType(iface) else { continue }
            if CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) {
                result.kinds[bsd] = .wifi
            } else if CFEqual(type, kSCNetworkInterfaceTypeEthernet) {
                result.kinds[bsd] = .ethernet
            } else if CFEqual(type, kSCNetworkInterfaceTypePPP) || CFEqual(type, kSCNetworkInterfaceTypeIPSec) {
                result.kinds[bsd] = .vpn
            }
        }
        return result
    }
}

/// Reads the routing table through `sysctl(NET_RT_FLAGS)`.
enum RoutingTable {
    /// Default IPv4 gateway per interface index.
    static func defaultGateways() -> [UInt32: IPv4Address] {
        var result: [UInt32: IPv4Address] = [:]
        var scoped: [UInt32: IPv4Address] = [:]
        forEachRoute(family: AF_INET, flags: RTF_GATEWAY) { index, flags, addrs in
            guard case .v4(let dst)? = addrs[Int(RTAX_DST)], dst.value == 0,
                  case .v4(let gw)? = addrs[Int(RTAX_GATEWAY)] else { return }
            if flags & RTF_IFSCOPE != 0 {
                if scoped[index] == nil { scoped[index] = gw }
            } else if result[index] == nil {
                result[index] = gw
            }
        }
        return scoped.merging(result) { _, unscoped in unscoped }
    }

    /// The interface carrying the unscoped default route.
    static func primaryInterfaceIndex() -> UInt32? {
        var primary: UInt32?
        forEachRoute(family: AF_INET, flags: RTF_GATEWAY) { index, flags, addrs in
            guard primary == nil, flags & RTF_IFSCOPE == 0,
                  case .v4(let dst)? = addrs[Int(RTAX_DST)], dst.value == 0 else { return }
            primary = index
        }
        return primary
    }

    enum Address {
        case v4(IPv4Address)
        case v6(IPv6Address)
        case link(MACAddress?, index: UInt16)
        case other
    }

    /// Iterates route messages; `body` receives interface index, flags and sockaddrs keyed by RTAX index.
    static func forEachRoute(family: Int32, flags: Int32, _ body: (UInt32, Int32, [Int: Address]) -> Void) {
        forEachRouteMessage(family: family, flags: flags) { header, addrs in
            body(UInt32(header.rtm_index), header.rtm_flags, addrs)
        }
    }

    /// Like `forEachRoute`, but hands out the whole message header (metrics included).
    static func forEachRouteMessage(family: Int32, flags: Int32, _ body: (rt_msghdr, [Int: Address]) -> Void) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, flags]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return }
        let headerSize = MemoryLayout<rt_msghdr>.size
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + headerSize <= length {
                let header = base.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let msgLength = Int(header.rtm_msglen)
                guard msgLength > 0, offset + msgLength <= length else { break }
                var addrs: [Int: Address] = [:]
                var p = offset + headerSize
                for i in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << Int32(i)) != 0 {
                    guard p < offset + msgLength else { break }
                    let saLen = Int(raw[p])
                    let family = Int32(raw[p + 1])
                    switch family {
                    case AF_INET where saLen >= 8:
                        addrs[i] = .v4(IPv4Address(raw[p + 4], raw[p + 5], raw[p + 6], raw[p + 7]))
                    case AF_INET6 where saLen >= 24:
                        addrs[i] = .v6(IPv6Address(bytes: raw[(p + 8)..<(p + 24)]).withoutEmbeddedScope)
                    case AF_LINK:
                        let index = base.loadUnaligned(fromByteOffset: p + 2, as: UInt16.self)
                        addrs[i] = .link(NetworkInterface.linkAddress(base + p), index: index)
                    default:
                        addrs[i] = i == Int(RTAX_DST) && saLen == 0 ? .v4(IPv4Address(0)) : .other
                    }
                    p += saLen > 0 ? (saLen + 3) & ~3 : 4
                }
                body(header, addrs)
                offset += msgLength
            }
        }
    }
}

/// System DNS resolvers.
public enum SystemDNS {
    public static func servers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "LanDetector" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dict["ServerAddresses"] as? [String] else { return [] }
        return servers
    }
}
