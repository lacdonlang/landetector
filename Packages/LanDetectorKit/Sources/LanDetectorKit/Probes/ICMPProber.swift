import Darwin
import Foundation
import Synchronization

/// Unprivileged ICMP echo (SOCK_DGRAM + IPPROTO_ICMP) for fast IPv4 sweeps and RTT measurements.
public final class ICMPProber: @unchecked Sendable {
    private let socket: DatagramSocket
    private let identifier: UInt16
    private static let magic: [UInt8] = Array("LDET".utf8)

    public init() throws {
        socket = try DatagramSocket(family: AF_INET, protocol: IPPROTO_ICMP, label: "icmp")
        identifier = UInt16.random(in: 1...UInt16.max)
    }

    deinit { socket.close() }

    /// `handler(ip, rttMilliseconds)` runs on the socket queue.
    public func start(_ handler: @escaping @Sendable (IPv4Address, Double) -> Void) {
        let identifier = self.identifier
        socket.startReceiving { data, from in
            guard case .v4(let ip, _) = from, data.count >= 20 else { return }
            let ihl = Int(data[0] & 0x0F) * 4 // IPv4 header is included on DGRAM ICMP sockets
            let icmp = ihl
            guard data.count >= icmp + 20, data[icmp] == 0 /* echo reply */,
                  UInt16(data[icmp + 4]) << 8 | UInt16(data[icmp + 5]) == identifier,
                  Array(data[(icmp + 16)..<(icmp + 20)]) == ICMPProber.magic else { return }
            let sent = data[(icmp + 8)..<(icmp + 16)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let now = DispatchTime.now().uptimeNanoseconds
            let rtt = now > sent ? Double(now - sent) / 1_000_000 : 0
            handler(ip, rtt)
        }
    }

    public func ping(_ ip: IPv4Address, sequence: UInt16 = 0) {
        socket.send(Self.packet(type: 8, identifier: identifier, sequence: sequence), to: ip, port: 0)
    }

    /// Sends echo requests to every host, `burst` packets at a time with a short pause in between.
    public func sweep(_ hosts: [IPv4Address], burst: Int = 32, pause: Duration = .milliseconds(3),
                      progress: (@Sendable (Double) -> Void)? = nil) async {
        var index = 0
        while index < hosts.count {
            if Task.isCancelled { return }
            let end = min(index + burst, hosts.count)
            for i in index..<end { ping(hosts[i], sequence: UInt16(truncatingIfNeeded: i)) }
            index = end
            progress?(Double(index) / Double(hosts.count))
            try? await Task.sleep(for: pause)
        }
    }

    public func close() { socket.close() }

    static func packet(type: UInt8, identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var p: [UInt8] = [type, 0, 0, 0,
                          UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                          UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        let t = DispatchTime.now().uptimeNanoseconds
        for shift in stride(from: 56, through: 0, by: -8) { p.append(UInt8(truncatingIfNeeded: t >> UInt64(shift))) }
        p += magic
        p += [UInt8](repeating: 0x61, count: 12)
        let sum = checksum(p)
        p[2] = UInt8(sum >> 8)
        p[3] = UInt8(sum & 0xFF)
        return p
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

/// ICMPv6 echo to the all-nodes multicast group, from the link-local and (optionally) a global source.
public final class ICMPv6Prober: @unchecked Sendable {
    private var sockets: [DatagramSocket] = []
    private let interface: NetworkInterface
    private let identifier = UInt16.random(in: 1...UInt16.max)
    private static let allNodes = IPv6Address("ff02::1")!

    public init(interface: NetworkInterface) {
        self.interface = interface
        if let s = try? DatagramSocket(family: AF_INET6, protocol: IPPROTO_ICMPV6, label: "icmp6.ll") {
            s.setOption(IPPROTO_IPV6, IPV6_MULTICAST_IF, interface.index)
            s.bindToInterface(index: interface.index)
            sockets.append(s)
        }
        if let global = interface.ipv6Global.first,
           let s = try? DatagramSocket(family: AF_INET6, protocol: IPPROTO_ICMPV6, label: "icmp6.gl"),
           (try? s.bind6(address: global)) != nil {
            s.setOption(IPPROTO_IPV6, IPV6_MULTICAST_IF, interface.index)
            sockets.append(s)
        }
    }

    deinit { close() }

    public func start(_ handler: @escaping @Sendable (IPv6Address, Double) -> Void) {
        let identifier = self.identifier
        let scope = interface.index
        for s in sockets {
            let replied = Mutex<Set<IPv6Address>>([])
            s.startReceiving { data, from in
                guard case .v6(let ip, _, _) = from, data.count >= 16, data[0] == 129,
                      UInt16(data[4]) << 8 | UInt16(data[5]) == identifier else { return }
                let sent = data[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                let now = DispatchTime.now().uptimeNanoseconds
                handler(ip, now > sent ? Double(now - sent) / 1_000_000 : 0)
                // A unicast echo makes the kernel resolve the neighbour, so it shows up in the NDP table.
                if replied.withLock({ $0.insert(ip).inserted }) {
                    var packet = ICMPProber.packet(type: 128, identifier: identifier, sequence: 0xFFFF)
                    packet[2] = 0
                    packet[3] = 0
                    s.send(packet, to: ip, scope: ip.isLinkLocal ? scope : 0)
                }
            }
        }
    }

    public func probe() {
        for (i, s) in sockets.enumerated() {
            // The kernel fills in the ICMPv6 checksum.
            var packet = ICMPProber.packet(type: 128, identifier: identifier, sequence: UInt16(i))
            packet[2] = 0
            packet[3] = 0
            s.send(packet, to: Self.allNodes, scope: interface.index)
        }
    }

    public func close() {
        for s in sockets { s.close() }
    }
}
