import Darwin
import Foundation

/// Grabs a short identifying string from open ports: the HTML `<title>` / `Server` header for
/// web ports and the greeting line for SSH, FTP, SMTP, Telnet and similar protocols.
public enum BannerGrabber {
    public static let tlsPorts: Set<UInt16> = [443, 4443, 5001, 7443, 8443, 9443, 10443]
    public static let httpPorts: Set<UInt16> = [80, 81, 591, 3000, 5000, 7080, 8000, 8008, 8080, 8081, 8088, 8123,
                                                8888, 9000, 9090, 10000, 32400]
    public static let linePorts: Set<UInt16> = [21, 22, 23, 25, 110, 143, 587, 3306, 5900]

    public static func canGrab(_ port: UInt16) -> Bool {
        tlsPorts.contains(port) || httpPorts.contains(port) || linePorts.contains(port)
    }

    public static func grab(_ ip: IPv4Address, port: UInt16) async -> String? {
        if tlsPorts.contains(port) { return await http(URL(string: "https://\(ip):\(port)/")) }
        if httpPorts.contains(port) { return await http(URL(string: "http://\(ip):\(port)/")) }
        if linePorts.contains(port) { return await line(ip, port: port) }
        return nil
    }

    // MARK: HTTP

    /// LAN devices almost always use self-signed certificates.
    private final class TrustingDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if let trust = challenge.protectionSpace.serverTrust {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.performDefaultHandling, nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) LanDetector/1.0"]
        return URLSession(configuration: config, delegate: TrustingDelegate(), delegateQueue: nil)
    }()

    static func http(_ url: URL?, followRefresh: Bool = true) async -> String? {
        guard let url, let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else { return nil }
        let html = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        // `<meta http-equiv="refresh" content="0; URL=cgi-bin/luci/">` – follow once.
        if followRefresh, let target = metaRefreshTarget(html), let next = URL(string: target, relativeTo: http.url ?? url),
           let followed = await self.http(next.absoluteURL, followRefresh: false) {
            return followed
        }
        let title = extractTitle(html) ?? extractTag("h1", html) ?? brandHint(html)
        let server = http.value(forHTTPHeaderField: "Server")
        switch (title, server) {
        case let (t?, s?): return "\(t) · \(s)"
        case let (t?, nil): return t
        case let (nil, s?): return "HTTP \(http.statusCode) · \(s)"
        default: return "HTTP \(http.statusCode)"
        }
    }

    static func metaRefreshTarget(_ html: String) -> String? {
        guard let meta = html.range(of: "http-equiv=\"refresh\"", options: .caseInsensitive),
              let content = html.range(of: "content=\"", options: .caseInsensitive, range: meta.upperBound..<html.endIndex),
              let end = html.range(of: "\"", range: content.upperBound..<html.endIndex) else { return nil }
        let value = html[content.upperBound..<end.lowerBound]
        guard let urlRange = value.range(of: "url=", options: .caseInsensitive) else { return nil }
        let target = value[urlRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        return target.isEmpty ? nil : target
    }

    static func extractTag(_ tag: String, _ html: String) -> String? {
        guard let start = html.range(of: "<\(tag)", options: .caseInsensitive),
              let open = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let close = html.range(of: "</\(tag)", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
        else { return nil }
        let inner = String(html[open.upperBound..<close.lowerBound])
        let stripped = inner.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let text = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(120))
    }

    /// Brand names that appear in login pages even when the title is empty or set by script.
    static let brands = ["OpenWrt", "H3C", "Huawei", "TP-Link", "ASUS", "Netgear", "MikroTik", "RouterOS",
                         "Ubiquiti", "UniFi", "Synology", "QNAP", "TrueNAS", "Proxmox", "Hikvision", "Dahua",
                         "Xiaomi", "Ruijie", "ZTE", "Tenda", "Mercury", "FAST", "D-Link", "Zyxel", "pfSense",
                         "OPNsense", "Home Assistant", "Pi-hole", "Plex", "Jellyfin", "Portainer", "Grafana"]

    static func brandHint(_ html: String) -> String? {
        let lower = html.lowercased()
        let found = brands.filter { lower.contains($0.lowercased()) }
        return found.isEmpty ? nil : "页面含 " + found.prefix(3).joined(separator: " / ")
    }

    static func extractTitle(_ html: String) -> String? {
        guard let start = html.range(of: "<title", options: .caseInsensitive),
              let open = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let close = html.range(of: "</title", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
        else { return nil }
        let raw = html[open.upperBound..<close.lowerBound]
        let decoded = raw.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
        let text = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(120))
    }

    // MARK: Line based protocols

    private static let queue = DispatchQueue(label: "landetector.banner", qos: .utility, attributes: .concurrent)

    static func line(_ ip: IPv4Address, port: UInt16) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: readGreeting(ip, port: port)) }
        }
    }

    private static func readGreeting(_ ip: IPv4Address, port: UInt16) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var sa = ip.sockaddr(port: port)
        let r = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 || errno == EINPROGRESS else { return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 1500) == 1 else { return nil }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        guard error == 0 else { return nil }
        pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 2000) == 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return nil }
        if port == 5900 { // "RFB 003.008"
            return String(decoding: buffer[0..<min(n, 12)], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if port == 3306 { // MySQL handshake: protocol byte then NUL-terminated version
            let start = 5
            guard n > start else { return nil }
            let version = buffer[start..<n].prefix { $0 != 0 }
            return "MySQL " + String(decoding: version, as: UTF8.self)
        }
        let text = String(decoding: buffer[0..<n], as: UTF8.self)
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let printable = first.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 || $0.value > 160 }
        let result = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : String(result.prefix(120))
    }
}
