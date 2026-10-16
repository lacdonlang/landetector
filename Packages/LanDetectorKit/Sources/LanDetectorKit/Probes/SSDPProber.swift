import Darwin
import Foundation

public struct SSDPResponse: Hashable, Sendable {
    public var location: URL?
    public var server: String?
    public var searchTarget: String?
    public var usn: String?
}

/// SSDP (UPnP discovery) M-SEARCH prober.
public final class SSDPProber: @unchecked Sendable {
    private static let group = IPv4Address(239, 255, 255, 250)
    private let socket: DatagramSocket

    public init(interface: NetworkInterface) throws {
        socket = try DatagramSocket(family: AF_INET, protocol: IPPROTO_UDP, label: "ssdp")
        socket.setMulticastInterface(interface.ipv4, ttl: 2)
        socket.bindToInterface(index: interface.index)
    }

    deinit { socket.close() }

    public func start(_ handler: @escaping @Sendable (IPv4Address, SSDPResponse) -> Void) {
        socket.startReceiving { data, from in
            guard case .v4(let ip, _) = from else { return }
            handler(ip, Self.parse(String(decoding: data, as: UTF8.self)))
        }
    }

    public func search() {
        socket.queue.async { [self] in
            for target in ["ssdp:all", "upnp:rootdevice"] {
                let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n" +
                    "MX: 2\r\nST: \(target)\r\nUSER-AGENT: macOS UPnP/1.1 LanDetector/1.0\r\n\r\n"
                socket.send(Array(message.utf8), to: Self.group, port: 1900)
            }
        }
    }

    /// Unicast M-SEARCH to a single host (some devices only answer these).
    public func search(_ ip: IPv4Address) {
        socket.queue.async { [self] in
            let message = "M-SEARCH * HTTP/1.1\r\nHOST: \(ip):1900\r\nMAN: \"ssdp:discover\"\r\n" +
                "ST: upnp:rootdevice\r\nUSER-AGENT: macOS UPnP/1.1 LanDetector/1.0\r\n\r\n"
            socket.send(Array(message.utf8), to: ip, port: 1900)
        }
    }

    public func close() { socket.close() }

    static func parse(_ text: String) -> SSDPResponse {
        var response = SSDPResponse()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "LOCATION": response.location = URL(string: value)
            case "SERVER": response.server = value
            case "ST", "NT": response.searchTarget = value
            case "USN": response.usn = value
            default: break
            }
        }
        return response
    }
}

/// Downloads and parses UPnP device description XML.
public enum UPnPFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public static func fetch(_ url: URL) async -> UPnPInfo? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
        var info = parse(data)
        info?.location = url.absoluteString
        return info
    }

    public static func parse(_ data: Data) -> UPnPInfo? {
        let delegate = DescriptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        let info = delegate.info
        guard info.friendlyName != nil || info.manufacturer != nil || info.modelName != nil else { return nil }
        return info
    }

    private final class DescriptionParser: NSObject, XMLParserDelegate {
        var info = UPnPInfo()
        private var text = ""
        private var deviceDepth = 0

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if element == "device" { deviceDepth += 1 }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            defer { text = "" }
            if element == "device" {
                deviceDepth -= 1
                return
            }
            // Only the root device describes the physical box.
            guard deviceDepth == 1 else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            switch element {
            case "friendlyName": info.friendlyName = info.friendlyName ?? value
            case "manufacturer": info.manufacturer = info.manufacturer ?? value
            case "manufacturerURL": info.manufacturerURL = info.manufacturerURL ?? value
            case "modelName": info.modelName = info.modelName ?? value
            case "modelNumber": info.modelNumber = info.modelNumber ?? value
            case "modelDescription": info.modelDescription = info.modelDescription ?? value
            case "deviceType": info.deviceType = info.deviceType ?? value
            case "serialNumber": info.serialNumber = info.serialNumber ?? value
            case "presentationURL": info.presentationURL = info.presentationURL ?? value
            default: break
            }
        }
    }
}

/// Reverse DNS (PTR) through the system resolver, with bounded concurrency.
public enum ReverseDNS {
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 24
        q.qualityOfService = .userInitiated
        q.name = "landetector.rdns"
        return q
    }()

    public static func lookup(_ ip: IPv4Address) async -> String? {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                var sa = ip.sockaddr(port: 0)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let r = withUnsafePointer(to: &sa) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count),
                                    nil, 0, NI_NAMEREQD)
                    }
                }
                var name: String?
                if r == 0 {
                    let s = String(cChars: host).trimmingDot
                    if !s.isEmpty, s != ip.description, IPv4Address(s) == nil { name = s }
                }
                continuation.resume(returning: name)
            }
        }
    }
}
