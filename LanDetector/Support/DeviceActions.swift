import AppKit
import LanDetectorKit
import UniformTypeIdentifiers
import UserNotifications

/// Actions that hand a device off to other apps.
@MainActor
enum DeviceActions {
    static func webURL(for d: Device) -> URL? {
        if let custom = d.customURL?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return URL(string: custom.contains("://") ? custom : "http://\(custom)")
        }
        if let presentation = d.upnp?.presentationURL, let url = URL(string: presentation), url.host != nil {
            return url
        }
        guard let ip = d.ipv4 else { return nil }
        let ports = Set(d.openPorts)
        if ports.contains(443) && !ports.contains(80) { return URL(string: "https://\(ip)") }
        for p: UInt16 in [80, 8080, 8000, 8081, 8888, 5000] where ports.contains(p) {
            return URL(string: p == 80 ? "http://\(ip)" : "http://\(ip):\(p)")
        }
        if ports.contains(443) { return URL(string: "https://\(ip)") }
        if let http = d.services.first(where: { $0.type == "_http._tcp" }), http.port != 0 {
            return URL(string: "http://\(ip):\(http.port)")
        }
        return URL(string: "http://\(ip)")
    }

    static func openWeb(_ d: Device) {
        if let url = webURL(for: d) { NSWorkspace.shared.open(url) }
    }

    static func openSSH(_ d: Device) {
        guard let ip = d.ipv4 else { return }
        NSWorkspace.shared.open(URL(string: "ssh://\(ip)")!)
    }

    static func openSMB(_ d: Device) {
        guard let ip = d.ipv4 else { return }
        NSWorkspace.shared.open(URL(string: "smb://\(ip)")!)
    }

    static func openVNC(_ d: Device) {
        guard let ip = d.ipv4 else { return }
        NSWorkspace.shared.open(URL(string: "vnc://\(ip)")!)
    }

    static func wake(_ d: Device, broadcast: IPv4Address?) {
        guard let mac = d.mac else { return }
        try? WakeOnLAN.wake(mac, broadcast: broadcast)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func hasWeb(_ d: Device) -> Bool {
        d.customURL != nil || d.upnp?.presentationURL != nil
            || !Set(d.openPorts).isDisjoint(with: [80, 443, 8080, 8000, 8081, 8443, 8888, 5000, 5001])
            || d.services.contains { $0.type == "_http._tcp" || $0.type == "_https._tcp" }
    }

    static func hasSSH(_ d: Device) -> Bool {
        d.openPorts.contains(22) || d.services.contains { $0.type == "_ssh._tcp" || $0.type == "_sftp-ssh._tcp" }
    }

    static func hasSMB(_ d: Device) -> Bool {
        d.openPorts.contains(445) || d.netbiosName != nil || d.services.contains { $0.type == "_smb._tcp" }
    }

    static func hasVNC(_ d: Device) -> Bool {
        d.openPorts.contains(5900) || d.services.contains { $0.type == "_rfb._tcp" }
    }
}

/// Local notifications for newly discovered devices.
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyNewDevices(_ devices: [Device]) {
        let content = UNMutableNotificationContent()
        if devices.count == 1, let d = devices.first {
            content.title = "发现新设备"
            content.body = [d.displayName, d.ipv4?.description, d.vendor].compactMap { $0 }.joined(separator: " · ")
        } else {
            content.title = "发现 \(devices.count) 台新设备"
            content.body = devices.prefix(4).map(\.displayName).joined(separator: "、")
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Writes scan results in the formats LanScan offers (plus JSON / Markdown).
@MainActor
enum Exporter {
    enum Format: String, CaseIterable, Identifiable {
        case csv, csvSemicolon, tsv, psv, json, markdown

        var id: String { rawValue }

        var title: String {
            switch self {
            case .csv: "CSV（逗号分隔）"
            case .csvSemicolon: "CSV（分号分隔）"
            case .tsv: "TSV（制表符分隔）"
            case .psv: "PSV（竖线分隔）"
            case .json: "JSON"
            case .markdown: "Markdown 表格"
            }
        }

        var fileExtension: String {
            switch self {
            case .csv, .csvSemicolon: "csv"
            case .tsv: "tsv"
            case .psv: "txt"
            case .json: "json"
            case .markdown: "md"
            }
        }

        var separator: String {
            switch self {
            case .csv: ","
            case .csvSemicolon: ";"
            case .tsv: "\t"
            case .psv: "|"
            default: ","
            }
        }
    }

    static let headers = ["名称", "状态", "IPv4", "MAC", "厂商", "类型", "型号", "系统", "DNS 名称", "mDNS 名称", "SMB 名称",
                          "SMB 工作组", "IPv6 本地", "IPv6 全局", "开放端口", "延迟(ms)", "首次发现", "最后在线", "备注"]

    static func row(_ d: Device) -> [String] {
        let df = ISO8601DateFormatter()
        return [d.displayName, d.isOnline ? "在线" : "离线", d.ipv4?.description ?? "", d.mac?.description ?? "",
                d.vendorFull ?? "", d.effectiveKind.title, d.model ?? "", d.osName ?? "", d.dnsName ?? "", d.mdnsName ?? "",
                d.netbiosName ?? "", d.netbiosGroup ?? "", d.ipv6LinkLocal.map(\.description).joined(separator: " "),
                d.ipv6Routable.map(\.description).joined(separator: " "), d.openPortsText,
                d.latency.map { String(format: "%.1f", $0) } ?? "", df.string(from: d.firstSeen), df.string(from: d.lastSeen),
                d.notes.replacingOccurrences(of: "\n", with: " ")]
    }

    static func render(_ devices: [Device], as format: Format) -> String {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return (try? encoder.encode(devices)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        case .markdown:
            var lines = ["| " + headers.joined(separator: " | ") + " |",
                         "|" + String(repeating: " --- |", count: headers.count)]
            for d in devices {
                lines.append("| " + row(d).map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |")
            }
            return lines.joined(separator: "\n") + "\n"
        default:
            let sep = format.separator
            func field(_ s: String) -> String {
                guard format == .csv || format == .csvSemicolon else { return s.replacingOccurrences(of: sep, with: " ") }
                if s.contains(sep) || s.contains("\"") || s.contains("\n") {
                    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return s
            }
            var lines = [headers.map(field).joined(separator: sep)]
            for d in devices { lines.append(row(d).map(field).joined(separator: sep)) }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func export(_ devices: [Device], as format: Format) {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "LanDetector-\(stamp).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A BOM lets Excel open Chinese CSV correctly.
        let text = render(devices, as: format)
        let data = (format == .csv || format == .csvSemicolon ? "\u{FEFF}" : "") + text
        try? data.write(to: url, atomically: true, encoding: .utf8)
    }

    static func exportCustomNames(_ records: [CustomNameRecord]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LanDetector-自定义名称.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(records).write(to: url, options: .atomic)
    }

    static func pickCustomNamesFile() -> [CustomNameRecord]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CustomNameRecord].self, from: data)
    }
}

extension BonjourService {
    /// Service types LanDetector has a friendly name for.
    var isKnownType: Bool { BonjourService.knownTypes[type] != nil }
}
