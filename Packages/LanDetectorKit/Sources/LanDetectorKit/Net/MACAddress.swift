import Foundation

/// A 48-bit IEEE 802 MAC address.
public struct MACAddress: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The address in the low 48 bits.
    public let value: UInt64

    public init(value: UInt64) { self.value = value & 0xFFFF_FFFF_FFFF }

    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 6 else { return nil }
        self.init(value: bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    }

    /// Parses `aa:bb:cc:dd:ee:ff`, `a:b:c:d:e:f`, `aa-bb-…`, `aabb.ccdd.eeff` and `aabbccddeeff`.
    public init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespaces)
        let separators: Set<Character> = [":", "-"]
        var bytes: [UInt8] = []
        if s.contains(where: { separators.contains($0) }) {
            let parts = s.split(whereSeparator: { separators.contains($0) })
            guard parts.count == 6 else { return nil }
            for part in parts {
                guard part.count <= 2, let b = UInt8(part, radix: 16) else { return nil }
                bytes.append(b)
            }
        } else {
            let hex = s.replacingOccurrences(of: ".", with: "")
            guard hex.count == 12, let v = UInt64(hex, radix: 16) else { return nil }
            self.init(value: v)
            return
        }
        self.init(bytes: bytes)
    }

    public var bytes: [UInt8] { (0..<6).map { UInt8(truncatingIfNeeded: value >> (40 - 8 * $0)) } }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public var firstOctet: UInt8 { UInt8(truncatingIfNeeded: value >> 40) }

    /// Locally administered addresses are typically randomised "private Wi-Fi addresses".
    public var isLocallyAdministered: Bool { firstOctet & 0x02 != 0 }
    public var isMulticast: Bool { firstOctet & 0x01 != 0 }
    public var isZero: Bool { value == 0 }
    public var isBroadcast: Bool { value == 0xFFFF_FFFF_FFFF }
    /// macOS 27 reports `02:00:00:00:00:00` to processes that may not see real addresses.
    public var isPlaceholder: Bool { value == 0x0200_0000_0000 }
    public var isUsable: Bool { !isZero && !isBroadcast && !isMulticast && !isPlaceholder }

    /// The top `bits` bits as upper-case hex (24 → 6 digits, 28 → 7, 36 → 9).
    public func prefix(bits: Int) -> UInt64 { value >> UInt64(48 - bits) }

    public static func < (lhs: MACAddress, rhs: MACAddress) -> Bool { lhs.value < rhs.value }
}

extension MACAddress: Codable {
    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let mac = MACAddress(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid MAC \(string)"))
        }
        self = mac
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
