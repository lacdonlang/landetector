import Foundation

public enum DNSRecordType: UInt16, Sendable {
    case a = 1, ptr = 12, hinfo = 13, txt = 16, aaaa = 28, srv = 33, nsec = 47, any = 255
}

public struct DNSQuestion: Sendable {
    public var name: String
    public var type: DNSRecordType
    /// mDNS "QU" bit – ask for a unicast response.
    public var unicastResponse: Bool

    public init(_ name: String, _ type: DNSRecordType, unicastResponse: Bool = false) {
        self.name = name
        self.type = type
        self.unicastResponse = unicastResponse
    }
}

public enum DNSRecordData: Sendable, Hashable {
    case a(IPv4Address)
    case aaaa(IPv6Address)
    case ptr(String)
    case srv(priority: UInt16, weight: UInt16, port: UInt16, target: String)
    case txt([String])
    case hinfo(cpu: String, os: String)
    case other(UInt16)
}

public struct DNSRecord: Sendable, Hashable {
    public var name: String
    public var type: UInt16
    public var ttl: UInt32
    public var data: DNSRecordData
}

public struct DNSMessage: Sendable {
    public var id: UInt16
    public var flags: UInt16
    public var questions: [String]
    public var answers: [DNSRecord]
    public var additionals: [DNSRecord]

    public var isResponse: Bool { flags & 0x8000 != 0 }
    public var records: [DNSRecord] { answers + additionals }
}

/// Minimal DNS wire-format encoder/decoder (RFC 1035 + mDNS bits from RFC 6762).
public enum DNSCodec {
    public static func query(id: UInt16 = 0, _ questions: [DNSQuestion]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(64 * questions.count)
        append16(&out, id)
        append16(&out, 0) // standard query
        append16(&out, UInt16(questions.count))
        append16(&out, 0)
        append16(&out, 0)
        append16(&out, 0)
        for q in questions {
            appendName(&out, q.name)
            append16(&out, q.type.rawValue)
            append16(&out, q.unicastResponse ? 0x8001 : 0x0001)
        }
        return out
    }

    public static func decode(_ bytes: [UInt8]) -> DNSMessage? {
        var reader = Reader(bytes: bytes)
        guard let id = reader.u16(), let flags = reader.u16(), let qd = reader.u16(), let an = reader.u16(),
              let ns = reader.u16(), let ar = reader.u16() else { return nil }
        var questions: [String] = []
        for _ in 0..<qd {
            guard let name = reader.name(), reader.skip(4) else { return nil }
            questions.append(name)
        }
        var answers: [DNSRecord] = []
        for _ in 0..<an {
            guard let r = reader.record() else { break }
            answers.append(r)
        }
        var additionals: [DNSRecord] = []
        for _ in 0..<(Int(ns) + Int(ar)) {
            guard let r = reader.record() else { break }
            additionals.append(r)
        }
        return DNSMessage(id: id, flags: flags, questions: questions, answers: answers, additionals: additionals)
    }

    /// Splits TXT strings into a key/value dictionary (`key=value`, bare keys map to "").
    public static func txtDictionary(_ strings: [String]) -> [String: String] {
        var dict: [String: String] = [:]
        for s in strings where !s.isEmpty {
            if let eq = s.firstIndex(of: "=") {
                let key = String(s[..<eq]).lowercased()
                if dict[key] == nil { dict[key] = String(s[s.index(after: eq)...]) }
            } else if dict[s.lowercased()] == nil {
                dict[s.lowercased()] = ""
            }
        }
        return dict
    }

    // MARK: - Encoding helpers

    private static func append16(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(v >> 8))
        out.append(UInt8(v & 0xFF))
    }

    private static func appendName(_ out: inout [UInt8], _ name: String) {
        for label in splitLabels(name) {
            let bytes = Array(label.utf8.prefix(63))
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(0)
    }

    /// Splits on dots, honouring `\.` escapes used in service instance names.
    static func splitLabels(_ name: String) -> [String] {
        var labels: [String] = []
        var current = ""
        var escaped = false
        for ch in name {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "." {
                if !current.isEmpty { labels.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { labels.append(current) }
        return labels
    }

    // MARK: - Decoding

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func u8() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() -> UInt16? {
            guard offset + 2 <= bytes.count else { return nil }
            defer { offset += 2 }
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }

        mutating func u32() -> UInt32? {
            guard let hi = u16(), let lo = u16() else { return nil }
            return UInt32(hi) << 16 | UInt32(lo)
        }

        mutating func skip(_ n: Int) -> Bool {
            guard offset + n <= bytes.count else { return false }
            offset += n
            return true
        }

        /// Reads a possibly compressed name; dots inside labels are escaped as `\.`.
        mutating func name() -> String? {
            var labels: [String] = []
            var position = offset
            var jumped = false
            var jumps = 0
            while true {
                guard position < bytes.count else { return nil }
                let length = Int(bytes[position])
                if length == 0 {
                    position += 1
                    break
                }
                if length & 0xC0 == 0xC0 {
                    guard position + 1 < bytes.count, jumps < 32 else { return nil }
                    let pointer = (length & 0x3F) << 8 | Int(bytes[position + 1])
                    if !jumped { offset = position + 2 }
                    jumped = true
                    jumps += 1
                    position = pointer
                    continue
                }
                guard position + 1 + length <= bytes.count else { return nil }
                let label = String(decoding: bytes[(position + 1)..<(position + 1 + length)], as: UTF8.self)
                labels.append(label.replacingOccurrences(of: ".", with: "\\."))
                position += 1 + length
            }
            if !jumped { offset = position }
            return labels.joined(separator: ".")
        }

        mutating func record() -> DNSRecord? {
            guard let owner = name(), let type = u16(), u16() != nil, let ttl = u32(), let length = u16() else {
                return nil
            }
            let end = offset + Int(length)
            guard end <= bytes.count else { return nil }
            defer { offset = end }
            let data: DNSRecordData
            switch DNSRecordType(rawValue: type) {
            case .a where length == 4:
                data = .a(IPv4Address(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]))
            case .aaaa where length == 16:
                data = .aaaa(IPv6Address(bytes: bytes[offset..<end]))
            case .ptr:
                guard let target = name() else { return nil }
                data = .ptr(target)
            case .srv:
                guard let priority = u16(), let weight = u16(), let port = u16(), let target = name() else { return nil }
                data = .srv(priority: priority, weight: weight, port: port, target: target)
            case .txt:
                var strings: [String] = []
                var p = offset
                while p < end {
                    let l = Int(bytes[p])
                    guard p + 1 + l <= end else { break }
                    strings.append(String(decoding: bytes[(p + 1)..<(p + 1 + l)], as: UTF8.self))
                    p += 1 + l
                }
                data = .txt(strings)
            case .hinfo:
                var p = offset
                func string() -> String {
                    guard p < end else { return "" }
                    let l = Int(bytes[p])
                    defer { p += 1 + l }
                    guard p + 1 + l <= end else { return "" }
                    return String(decoding: bytes[(p + 1)..<(p + 1 + l)], as: UTF8.self)
                }
                let cpu = string()
                data = .hinfo(cpu: cpu, os: string())
            default:
                data = .other(type)
            }
            return DNSRecord(name: owner, type: type, ttl: ttl, data: data)
        }
    }
}

extension String {
    /// Removes `\.` escapes for display.
    var dnsUnescaped: String { replacingOccurrences(of: "\\.", with: ".") }

    /// Lower-cased name without trailing dot, used as a dictionary key.
    var dnsKey: String {
        var s = lowercased()
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
