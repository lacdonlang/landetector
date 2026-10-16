import Darwin
import Foundation

/// NetBIOS node status (NBSTAT, UDP 137) – yields the SMB/Windows computer name and workgroup.
public final class NetBIOSProber: @unchecked Sendable {
    private let socket: DatagramSocket
    private var transaction: UInt16 = 0x4C44

    public init(interface: NetworkInterface? = nil) throws {
        socket = try DatagramSocket(family: AF_INET, protocol: IPPROTO_UDP, label: "netbios")
        if let interface { socket.bindToInterface(index: interface.index) }
    }

    deinit { socket.close() }

    public func start(_ handler: @escaping @Sendable (IPv4Address, NetBIOSInfo) -> Void) {
        socket.startReceiving { data, from in
            guard case .v4(let ip, let port) = from, port == 137, let info = Self.parse(data) else { return }
            handler(ip, info)
        }
    }

    public func probe(_ ip: IPv4Address) {
        socket.queue.async { [self] in
            transaction &+= 1
            socket.send(Self.request(id: transaction), to: ip, port: 137)
        }
    }

    public func close() { socket.close() }

    static func request(id: UInt16) -> [UInt8] {
        var p: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x00, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        // "*" padded with NULs to 16 bytes, first-level encoded (RFC 1001 §14.1).
        var name = [UInt8](repeating: 0, count: 16)
        name[0] = 0x2A
        p.append(0x20)
        for b in name {
            p.append(0x41 + (b >> 4))
            p.append(0x41 + (b & 0x0F))
        }
        p.append(0x00)
        p += [0x00, 0x21, 0x00, 0x01] // NBSTAT, IN
        return p
    }

    static func parse(_ d: [UInt8]) -> NetBIOSInfo? {
        guard d.count > 56, d[2] & 0x80 != 0 else { return nil }
        var p = 12
        // Answer name: either a pointer or the full encoded name.
        if d[p] & 0xC0 == 0xC0 {
            p += 2
        } else {
            while p < d.count, d[p] != 0 { p += Int(d[p]) + 1 }
            p += 1
        }
        p += 10 // type, class, ttl, rdlength
        guard p < d.count else { return nil }
        let count = Int(d[p])
        p += 1
        var names: [String] = []
        var workstation: String?
        var server: String?
        var group: String?
        for _ in 0..<count {
            guard p + 18 <= d.count else { break }
            let raw = d[p..<(p + 15)]
            let name = String(decoding: raw, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            let suffix = d[p + 15]
            let isGroup = d[p + 16] & 0x80 != 0
            if !name.isEmpty, !name.hasPrefix("\u{1}\u{2}__MSBROWSE__") {
                names.append(name)
                if !isGroup && suffix == 0x00 && workstation == nil { workstation = name }
                if !isGroup && suffix == 0x20 && server == nil { server = name }
                if isGroup && suffix == 0x00 && group == nil { group = name }
            }
            p += 18
        }
        var mac: MACAddress?
        if p + 6 <= d.count, let m = MACAddress(bytes: d[p..<(p + 6)]), m.isUsable { mac = m }
        let primary = workstation ?? server ?? names.first
        guard primary != nil else { return nil }
        return NetBIOSInfo(name: primary, group: group, mac: mac, names: Array(Set(names)).sorted())
    }
}
