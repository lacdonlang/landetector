import Foundation
import LanDetectorKit

// Command line harness for the scan engine.
//   landetector-cli interfaces
//   landetector-cli scan [en0] [--range 192.168.1.1-254] [--dns 192.168.1.1,…] [--verbose]
//   landetector-cli ports <ip> [common|well-known|all|22,80,443]

func pad(_ s: String, _ n: Int) -> String {
    let w = s.count
    return w >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - w)
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "scan"

switch command {
case "interfaces":
    for i in NetworkInterface.all() {
        print("\(i.name) \(i.displayName) [\(i.kind)] \(i.cidr) gw=\(i.gateway?.description ?? "-") mac=\(i.mac?.description ?? "-") v6=\(i.ipv6.map(\.description))")
    }
    print("DNS:", SystemDNS.servers())

case "scan":
    let interfaces = NetworkInterface.all()
    let name = args.dropFirst().first { arg in !arg.hasPrefix("--") && interfaces.contains { $0.name == arg } }
    guard let iface = interfaces.first(where: { $0.name == name }) ?? interfaces.first else {
        print("no interface"); exit(1)
    }
    var options = ScanOptions()
    if let i = args.firstIndex(of: "--range"), i + 1 < args.count { options.range = IPv4Range(string: args[i + 1]) }
    if let i = args.firstIndex(of: "--dns"), i + 1 < args.count {
        options.extraDNSServers = args[i + 1].split(separator: ",").compactMap { IPv4Address(String($0)) }
    }
    let verbose = args.contains("--verbose")
    print("Scanning \(iface.name) \(iface.cidr) gw \(iface.gateway?.description ?? "-")…")
    let t0 = Date()
    var inventory = DeviceInventory()
    var first: TimeInterval?
    for await event in ScanEngine().scan(iface, options: options) {
        let changed = inventory.apply(event)
        if first == nil, !changed.isEmpty { first = Date().timeIntervalSince(t0) }
        if verbose {
            switch event {
            case .progress: break
            case .neighbors(let e, let s): print(String(format: "%6.2fs", Date().timeIntervalSince(t0)), "neighbors", e.count, s)
            default: print(String(format: "%6.2fs", Date().timeIntervalSince(t0)), event)
            }
        }
        if case .finished(let summary) = event {
            inventory.finishScan()
            print(String(format: "Finished in %.2fs (first result %.2fs), %d hosts probed, neighbours via %@",
                         summary.duration, first ?? 0, summary.hostsProbed, summary.neighborSource.rawValue))
        }
    }
    let devices = inventory.allDevices.filter(\.isOnline).sorted { $0.sortableIP < $1.sortableIP }
    print("\(devices.count) devices online\n")
    print(pad("IP", 16), pad("MAC", 18), pad("名称", 28), pad("类型", 8), pad("型号/厂商", 34), "延迟")
    for d in devices {
        print(pad(d.ipv4?.description ?? "-", 16), pad(d.mac?.description ?? "-", 18), pad(d.displayName, 28),
              pad(d.effectiveKind.title, 8), pad(d.subtitle, 34), d.latency.map { String(format: "%.1fms", $0) } ?? "-")
        if verbose {
            if let v = d.dnsName { print("    dns:", v) }
            if let v = d.mdnsName { print("    mdns:", v) }
            if let v = d.netbiosName { print("    netbios:", v, d.netbiosGroup ?? "") }
            if let u = d.upnp { print("    upnp:", u.friendlyName ?? "", u.manufacturer ?? "", u.modelName ?? "", u.shortDeviceType ?? "", u.server ?? "") }
            for s in d.services { print("    svc:", s.type, "\"\(s.name)\"", s.port, s.txt.isEmpty ? "" : s.txt.description) }
            if !d.ipv6.isEmpty { print("    v6:", d.ipv6.map(\.description).joined(separator: ", ")) }
        }
    }

case "ports":
    guard args.count >= 2, let ip = IPv4Address(args[1]) else { print("usage: ports <ip> [preset]"); exit(1) }
    let spec = args.count > 2 ? args[2] : "common"
    let ports: [UInt16] = switch spec {
    case "common": PortPreset.commonPorts
    case "well-known": Array(1...1024)
    case "all": Array(1...65535)
    default: PortScanner.parsePorts(spec)
    }
    let t0 = Date()
    let rtt = await LatencyProbe.ping([ip], timeout: .milliseconds(500))[ip]
    let options = PortScanner.Options.adaptive(portCount: ports.count, rtt: rtt)
    print("rtt", rtt ?? -1, "timeout", options.timeout, "concurrency", options.concurrency)
    let open = await PortScanner.scan(ports.map { PortTarget(ip: ip, port: $0) }, options: options, onOpen: { t in
        print("  open \(PortDatabase.shared.label(for: t.port))")
    })
    print(String(format: "%d/%d open in %.2fs", open.count, ports.count, Date().timeIntervalSince(t0)))
    for t in open where BannerGrabber.canGrab(t.port) {
        print("  \(t.port) banner:", await BannerGrabber.grab(t.ip, port: t.port) ?? "-")
    }

default:
    print("unknown command \(command)")
}
