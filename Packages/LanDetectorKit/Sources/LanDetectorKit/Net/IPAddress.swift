import Darwin
import Foundation

/// An IPv4 address stored in host byte order.
public struct IPv4Address: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    public init?(_ string: String) {
        var addr = in_addr()
        guard inet_pton(AF_INET, string.trimmingCharacters(in: .whitespaces), &addr) == 1 else { return nil }
        value = UInt32(bigEndian: addr.s_addr)
    }

    public init(_ addr: in_addr) { value = UInt32(bigEndian: addr.s_addr) }

    public var inAddr: in_addr { in_addr(s_addr: value.bigEndian) }

    public var octets: (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value))
    }

    public var description: String {
        let o = octets
        return "\(o.0).\(o.1).\(o.2).\(o.3)"
    }

    /// `d.c.b.a.in-addr.arpa`
    public var reverseDNSName: String {
        let o = octets
        return "\(o.3).\(o.2).\(o.1).\(o.0).in-addr.arpa"
    }

    public var isLinkLocal: Bool { value >> 16 == 0xA9FE }
    public var isLoopback: Bool { value >> 24 == 127 }
    public var isMulticast: Bool { value >> 28 == 0xE }

    public var isPrivate: Bool {
        value >> 24 == 10 || value >> 20 == 0xAC1 || value >> 16 == 0xC0A8 || value >> 22 == 0x191 // 100.64/10
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool { lhs.value < rhs.value }

    public func sockaddr(port: UInt16) -> sockaddr_in {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = inAddr
        return sa
    }
}

extension IPv4Address: Codable {
    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let ip = IPv4Address(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid IPv4 \(string)"))
        }
        self = ip
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// An IPv6 address (16 bytes). Link-local addresses keep their scope id separately.
public struct IPv6Address: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let high: UInt64
    public let low: UInt64

    public init(bytes: some Collection<UInt8>) {
        precondition(bytes.count == 16)
        var h: UInt64 = 0, l: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            if i < 8 { h = h << 8 | UInt64(b) } else { l = l << 8 | UInt64(b) }
        }
        high = h
        low = l
    }

    public init(_ addr: in6_addr) {
        var a = addr
        let bytes = withUnsafeBytes(of: &a) { Array($0) }
        self.init(bytes: bytes)
    }

    public init?(_ string: String) {
        var s = string
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        var addr = in6_addr()
        guard inet_pton(AF_INET6, s, &addr) == 1 else { return nil }
        self.init(addr)
    }

    public var bytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: high >> (56 - 8 * $0)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: low >> (56 - 8 * $0)) }
    }

    public var in6Addr: in6_addr {
        var addr = in6_addr()
        let b = bytes
        withUnsafeMutableBytes(of: &addr) { raw in
            for i in 0..<16 { raw[i] = b[i] }
        }
        return addr
    }

    public var isLinkLocal: Bool { high >> 54 == 0x3FA } // fe80::/10
    public var isMulticast: Bool { high >> 56 == 0xFF }
    public var isUniqueLocal: Bool { high >> 57 == 0x7E } // fc00::/7
    public var isGlobal: Bool { high >> 61 == 0x1 } // 2000::/3

    /// The MAC address encoded in a modified EUI-64 interface identifier (`…ff:fe…`), if any.
    public var eui64MAC: MACAddress? {
        let b = bytes
        guard b[11] == 0xFF, b[12] == 0xFE else { return nil }
        let mac = MACAddress(bytes: [b[8] ^ 0x02, b[9], b[10], b[13], b[14], b[15]])
        return mac?.isUsable == true ? mac : nil
    }

    /// Removes the KAME-style scope id embedded in bytes 2–3 of link-local addresses.
    public var withoutEmbeddedScope: IPv6Address {
        guard isLinkLocal else { return self }
        var b = bytes
        b[2] = 0
        b[3] = 0
        return IPv6Address(bytes: b)
    }

    public var description: String {
        var addr = in6Addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
        return String(cChars: buffer)
    }

    public static func < (lhs: IPv6Address, rhs: IPv6Address) -> Bool {
        (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }
}

extension IPv6Address: Codable {
    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let ip = IPv6Address(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid IPv6 \(string)"))
        }
        self = ip
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// An inclusive range of IPv4 addresses.
public struct IPv4Range: Hashable, Sendable, Sequence, CustomStringConvertible, Codable {
    public let lower: IPv4Address
    public let upper: IPv4Address

    public init(lower: IPv4Address, upper: IPv4Address) {
        self.lower = Swift.min(lower, upper)
        self.upper = Swift.max(lower, upper)
    }

    /// Usable host addresses of the subnet (network and broadcast excluded for prefixes < 31).
    public static func subnet(address: IPv4Address, netmask: IPv4Address) -> IPv4Range {
        let network = address.value & netmask.value
        let broadcast = network | ~netmask.value
        if netmask.value.nonzeroBitCount >= 31 {
            return IPv4Range(lower: IPv4Address(network), upper: IPv4Address(broadcast))
        }
        return IPv4Range(lower: IPv4Address(network + 1), upper: IPv4Address(broadcast - 1))
    }

    /// Accepts `a.b.c.d`, `a.b.c.d/24`, `a.b.c.d-e.f.g.h` and `a.b.c.d-200`.
    public init?(string raw: String) {
        let s = raw.replacingOccurrences(of: " ", with: "")
        if let slash = s.firstIndex(of: "/") {
            guard let ip = IPv4Address(String(s[..<slash])),
                  let bits = Int(s[s.index(after: slash)...]), (0...32).contains(bits) else { return nil }
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - UInt32(bits))
            self = .subnet(address: ip, netmask: IPv4Address(mask))
            return
        }
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        guard let first = parts.first, let start = IPv4Address(first) else { return nil }
        if parts.count == 1 {
            self.init(lower: start, upper: start)
            return
        }
        if let end = IPv4Address(parts[1]) {
            self.init(lower: start, upper: end)
        } else if let lastOctet = UInt8(parts[1]) {
            self.init(lower: start, upper: IPv4Address(start.value & 0xFFFF_FF00 | UInt32(lastOctet)))
        } else {
            return nil
        }
    }

    public var count: Int { Int(upper.value) - Int(lower.value) + 1 }

    public func contains(_ ip: IPv4Address) -> Bool { ip >= lower && ip <= upper }

    public var description: String { lower == upper ? lower.description : "\(lower) – \(upper)" }

    public func makeIterator() -> Iterator { Iterator(cursor: UInt64(lower.value), end: UInt64(upper.value)) }

    public struct Iterator: IteratorProtocol {
        var cursor: UInt64
        let end: UInt64
        public mutating func next() -> IPv4Address? {
            guard cursor <= end else { return nil }
            defer { cursor += 1 }
            return IPv4Address(UInt32(cursor))
        }
    }

    /// The first `limit` addresses, centred on `anchor` when the range is larger than `limit`.
    public func clamped(to limit: Int, around anchor: IPv4Address) -> IPv4Range {
        guard count > limit else { return self }
        let half = UInt32(limit / 2)
        var low = anchor.value > lower.value + half ? anchor.value - half : lower.value
        if UInt64(low) + UInt64(limit) - 1 > UInt64(upper.value) { low = upper.value - UInt32(limit) + 1 }
        return IPv4Range(lower: IPv4Address(low), upper: IPv4Address(low + UInt32(limit) - 1))
    }
}

extension String {
    /// Decodes a NUL-terminated C character buffer.
    init(cChars buffer: [CChar]) {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self = String(decoding: bytes, as: UTF8.self)
    }
}
