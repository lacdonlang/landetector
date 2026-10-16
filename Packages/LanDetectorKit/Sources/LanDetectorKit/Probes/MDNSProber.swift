import Darwin
import Foundation

/// Active mDNS / DNS-SD prober.
///
/// Uses a single ephemeral-port socket: queries sent from a port other than 5353 are
/// "legacy unicast" queries, which responders answer by unicast directly to us
/// (RFC 6762 §6.7). That works alongside mDNSResponder without binding 5353.
public final class MDNSProber: @unchecked Sendable {
    public static let commonServiceTypes = [
        "_airplay._tcp", "_raop._tcp", "_companion-link._tcp", "_device-info._tcp", "_googlecast._tcp",
        "_spotify-connect._tcp", "_sonos._tcp", "_hap._tcp", "_homekit._tcp", "_matter._tcp",
        "_printer._tcp", "_ipp._tcp", "_ipps._tcp", "_pdl-datastream._tcp", "_uscan._tcp", "_scanner._tcp",
        "_smb._tcp", "_afpovertcp._tcp", "_adisk._tcp", "_ssh._tcp", "_sftp-ssh._tcp", "_rfb._tcp",
        "_http._tcp", "_workstation._tcp", "_sleep-proxy._udp", "_apple-mobdev2._tcp", "_airport._tcp",
        "_amzn-wplay._tcp", "_androidtvremote2._tcp", "_meshcop._udp", "_hue._tcp", "_axis-video._tcp",
        "_rtsp._tcp", "_esphomelib._tcp", "_home-assistant._tcp", "_mqtt._tcp", "_shelly._tcp",
        "_elg._tcp", "_wled._tcp", "_nanoleafapi._tcp", "_daap._tcp", "_plexmediasvr._tcp",
        "_nvstream._tcp", "_viziocast._tcp", "_tidalconnect._tcp", "_beocore._tcp", "_qdiscover._tcp",
        "_miio._udp", "_mediaremotetv._tcp", "_remotepairing._tcp",
    ]

    private static let group = IPv4Address(224, 0, 0, 251)
    private static let servicesMeta = "_services._dns-sd._udp.local"

    private let socket: DatagramSocket
    private var handler: (@Sendable (IPv4Address, MDNSHostInfo) -> Void)?

    // State – confined to `socket.queue`.
    private var hostAddresses: [String: Set<IPv4Address>] = [:]
    private var hostIPv6: [String: Set<IPv6Address>] = [:]
    private var hostDisplay: [String: String] = [:]
    private var hostHINFO: [String: String] = [:]
    private var reverseNames: [IPv4Address: String] = [:]
    private var instanceType: [String: String] = [:]
    private var instanceName: [String: String] = [:]
    private var instanceSRV: [String: (target: String, port: UInt16)] = [:]
    private var instanceTXT: [String: [String: String]] = [:]
    private var instanceSource: [String: IPv4Address] = [:]
    private var typesQueriedMulticast: Set<String> = []
    private var typesQueriedPerHost: [IPv4Address: Set<String>] = [:]
    private var detailsQueried: Set<String> = []
    private var addressQueried: Set<String> = []
    private var emitted: [IPv4Address: MDNSHostInfo] = [:]

    public init(interface: NetworkInterface) throws {
        socket = try DatagramSocket(family: AF_INET, protocol: IPPROTO_UDP, label: "mdns")
        socket.setMulticastInterface(interface.ipv4)
        socket.setOption(IPPROTO_IP, IP_TTL, Int32(255))
        socket.bindToInterface(index: interface.index)
    }

    deinit { socket.close() }

    public func start(_ handler: @escaping @Sendable (IPv4Address, MDNSHostInfo) -> Void) {
        socket.queue.sync { self.handler = handler }
        socket.startReceiving { [weak self] data, from in
            guard let self, case .v4(let ip, _) = from, let message = DNSCodec.decode(data), message.isResponse else { return }
            self.handle(message, from: ip)
        }
    }

    /// Multicast service-type enumeration plus direct browsing of common types.
    public func browse() {
        socket.queue.async { [self] in
            var questions = [DNSQuestion(Self.servicesMeta, .ptr)]
            for type in Self.commonServiceTypes {
                let full = "\(type).local"
                typesQueriedMulticast.insert(full)
                questions.append(DNSQuestion(full, .ptr))
            }
            for chunk in questions.chunked(into: 24) {
                socket.send(DNSCodec.query(chunk), to: Self.group, port: 5353)
            }
        }
    }

    /// Unicast reverse lookup and service enumeration directed at one host.
    public func probe(_ ip: IPv4Address) {
        socket.queue.async { [self] in
            let questions = [
                DNSQuestion(ip.reverseDNSName, .ptr, unicastResponse: true),
                DNSQuestion(Self.servicesMeta, .ptr, unicastResponse: true),
            ]
            socket.send(DNSCodec.query(questions), to: ip, port: 5353)
        }
    }

    public func close() { socket.close() }

    // MARK: - Response handling (on socket queue)

    private func handle(_ message: DNSMessage, from source: IPv4Address) {
        var affected: Set<IPv4Address> = [source]
        var newMulticastTypes: [String] = []
        var hostTypes: [String] = []
        var needDetails: [String] = []

        for record in message.records {
            let key = record.name.dnsKey
            switch record.data {
            case .a(let ip):
                hostAddresses[key, default: []].insert(ip)
                if hostDisplay[key] == nil { hostDisplay[key] = record.name.dnsUnescaped.trimmingDot }
                affected.insert(ip)
            case .aaaa(let ip):
                hostIPv6[key, default: []].insert(ip.withoutEmbeddedScope)
            case .hinfo(let cpu, let os):
                hostHINFO[key] = [cpu, os].filter { !$0.isEmpty }.joined(separator: " ")
            case .ptr(let target):
                let targetKey = target.dnsKey
                if key.hasSuffix(".in-addr.arpa") {
                    if let ip = Self.ipFromReverse(key) {
                        reverseNames[ip] = target.dnsUnescaped.trimmingDot
                        hostAddresses[targetKey, default: []].insert(ip)
                        affected.insert(ip)
                    }
                } else if key == Self.servicesMeta {
                    guard targetKey.hasSuffix(".local"), targetKey.hasPrefix("_") else { continue }
                    if typesQueriedMulticast.insert(targetKey).inserted { newMulticastTypes.append(targetKey) }
                    if typesQueriedPerHost[source, default: []].insert(targetKey).inserted { hostTypes.append(targetKey) }
                } else if key.hasPrefix("_") {
                    instanceType[targetKey] = key
                    if instanceName[targetKey] == nil {
                        instanceName[targetKey] = Self.instanceLabel(target, type: record.name)
                    }
                    if instanceSource[targetKey] == nil { instanceSource[targetKey] = source }
                    needDetails.append(targetKey)
                }
            case .srv(_, _, let port, let target):
                instanceSRV[key] = (target.dnsKey, port)
                if instanceSource[key] == nil { instanceSource[key] = source }
                if instanceName[key] == nil, let (name, type) = Self.splitInstance(record.name) {
                    instanceName[key] = name
                    instanceType[key] = type
                }
            case .txt(let strings):
                instanceTXT[key] = DNSCodec.txtDictionary(strings)
                if instanceSource[key] == nil { instanceSource[key] = source }
            case .other:
                break
            }
        }

        // Follow-up queries.
        if !newMulticastTypes.isEmpty {
            for chunk in newMulticastTypes.chunked(into: 24) {
                socket.send(DNSCodec.query(chunk.map { DNSQuestion($0, .ptr) }), to: Self.group, port: 5353)
            }
        }
        if !hostTypes.isEmpty {
            for chunk in hostTypes.chunked(into: 24) {
                socket.send(DNSCodec.query(chunk.map { DNSQuestion($0, .ptr, unicastResponse: true) }), to: source, port: 5353)
            }
        }
        var detailQuestions: [IPv4Address: [DNSQuestion]] = [:]
        for instance in needDetails where (instanceSRV[instance] == nil || instanceTXT[instance] == nil) {
            guard detailsQueried.insert(instance).inserted else { continue }
            let target = instanceSource[instance] ?? source
            detailQuestions[target, default: []] += [DNSQuestion(instance, .srv, unicastResponse: true),
                                                      DNSQuestion(instance, .txt, unicastResponse: true)]
        }
        for (_, srv) in instanceSRV where hostAddresses[srv.target] == nil {
            guard addressQueried.insert(srv.target).inserted else { continue }
            detailQuestions[source, default: []].append(DNSQuestion(srv.target, .a, unicastResponse: true))
        }
        for (target, questions) in detailQuestions {
            for chunk in questions.chunked(into: 20) {
                socket.send(DNSCodec.query(chunk), to: target, port: 5353)
            }
        }

        // Instances whose host resolves to these IPs may have changed as well.
        emit(for: affected)
    }

    private func emit(for ips: Set<IPv4Address>) {
        guard let handler else { return }
        for ip in ips {
            let info = hostInfo(for: ip)
            guard info.hostname != nil || !info.services.isEmpty else { continue }
            if emitted[ip] != info {
                emitted[ip] = info
                handler(ip, info)
            }
        }
    }

    private func hostInfo(for ip: IPv4Address) -> MDNSHostInfo {
        var hostKeys = Set(hostAddresses.compactMap { $0.value.contains(ip) ? $0.key : nil })
        var hostname = reverseNames[ip]
        var services: [BonjourService] = []
        for (instance, type) in instanceType {
            let owners: Set<IPv4Address>
            if let srv = instanceSRV[instance], let addrs = hostAddresses[srv.target], !addrs.isEmpty {
                owners = addrs
                if addrs.contains(ip) { hostKeys.insert(srv.target) }
            } else if let source = instanceSource[instance] {
                owners = [source]
            } else {
                continue
            }
            guard owners.contains(ip) else { continue }
            let shortType = type.hasSuffix(".local") ? String(type.dropLast(6)) : type
            services.append(BonjourService(type: shortType, name: instanceName[instance] ?? instance,
                                           port: instanceSRV[instance]?.port ?? 0, txt: instanceTXT[instance] ?? [:]))
        }
        if hostname == nil {
            hostname = hostKeys.sorted().compactMap { hostDisplay[$0] }.first
        }
        let v6 = hostKeys.flatMap { hostIPv6[$0] ?? [] }
        let hinfo = hostKeys.compactMap { hostHINFO[$0] }.first
        services.sort { ($0.type, $0.name) < ($1.type, $1.name) }
        return MDNSHostInfo(hostname: hostname, services: services, ipv6: Array(Set(v6)).sorted(), hinfo: hinfo)
    }

    // MARK: - Name helpers

    static func ipFromReverse(_ key: String) -> IPv4Address? {
        let parts = key.split(separator: ".")
        guard parts.count == 6, let d = UInt8(parts[0]), let c = UInt8(parts[1]),
              let b = UInt8(parts[2]), let a = UInt8(parts[3]) else { return nil }
        return IPv4Address(a, b, c, d)
    }

    /// "Living Room._airplay._tcp.local" with type "_airplay._tcp.local" → "Living Room".
    static func instanceLabel(_ instance: String, type: String) -> String {
        let lower = instance.lowercased(), typeLower = type.lowercased()
        if lower.hasSuffix("." + typeLower) {
            return String(instance.dropLast(type.count + 1)).dnsUnescaped
        }
        return splitInstance(instance)?.name ?? instance.dnsUnescaped
    }

    static func splitInstance(_ instance: String) -> (name: String, type: String)? {
        let labels = DNSCodec.splitLabels(instance)
        guard labels.count >= 4, labels[labels.count - 3].hasPrefix("_") else { return nil }
        let type = labels.suffix(3).joined(separator: ".").lowercased()
        let name = labels.dropLast(3).joined(separator: ".")
        return (name, type)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension String {
    var trimmingDot: String { hasSuffix(".") ? String(dropLast()) : self }
}
