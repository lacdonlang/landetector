#if DEBUG
import Foundation
import LanDetectorKit

/// Debug-only: a made-up home network for screenshots (`LANDETECTOR_DEMO=1`), so they show realistic vendors,
/// services and history without anyone's real devices. Names follow the app's language.
struct DemoNetwork {
    var interface: NetworkInterface
    var devices: [Device]
    var publicIP: PublicIPInfo
    var dnsServers: [String]
    var lastScan: ScanSummary
    var lastScanDate: Date

    /// How a device comes and goes, for its presence history.
    private enum Habit { case always, daytime, evenings, sometimes }

    private struct Spec {
        var host: UInt8
        var mac: String
        var kind: DeviceKind
        var name: String? = nil
        var custom: String? = nil
        var mdns: String? = nil
        var dns: String? = nil
        var netbios: String? = nil
        var model: String? = nil
        var os: String? = nil
        var services: [(String, UInt16)] = []
        var ports: [UInt16] = []
        var latency = 3.0
        var habit = Habit.always
        var online = true
        var lastSeenHoursAgo = 0.0
        var firstSeenHoursAgo = 30 * 24.0
        var favorite = false
        var watched = false
        var ipv6: [String] = []
    }

    static func make(now: Date = Date()) -> DemoNetwork {
        let zh = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        func n(_ en: String, _ chinese: String) -> String { zh ? chinese : en }
        let specs: [Spec] = [
            Spec(host: 1, mac: "04:d9:f5:3a:7c:10", kind: .router, name: "RT-AX86U Pro", dns: "router.asus.com",
                 model: "RT-AX86U Pro", services: [("_http._tcp", 80)], ports: [53, 80, 443, 1900], latency: 1.8),
            Spec(host: 2, mac: "f4:92:bf:61:0a:2e", kind: .networkDevice, name: n("Hallway AP", "走廊 AP"),
                 dns: "u6-lite-hallway", model: "U6 Lite", ports: [22, 443], latency: 2.4),
            Spec(host: 10, mac: "00:11:32:8e:41:07", kind: .nas, mdns: "DiskStation.local", netbios: "DISKSTATION",
                 model: "DS923+", os: "DSM 7.2",
                 services: [("_smb._tcp", 445), ("_afpovertcp._tcp", 548), ("_adisk._tcp", 9), ("_http._tcp", 5000),
                            ("_ssh._tcp", 22)],
                 ports: [22, 80, 139, 443, 445, 5000, 5001], latency: 1.2, favorite: true),
            Spec(host: 23, mac: "f0:18:98:5c:2d:91", kind: .laptop, name: n("Alex’s MacBook Pro", "小林的 MacBook Pro"),
                 mdns: "Alexs-MacBook-Pro.local", model: "MacBook Pro (14-inch, M4 Pro, 2024)", os: "macOS 27",
                 services: [("_companion-link._tcp", 49_152), ("_ssh._tcp", 22), ("_rfb._tcp", 5900)],
                 ports: [22, 5900], latency: 0.1, habit: .daytime, ipv6: ["fe80::1c2b:4a9f:e31d:7a02"]),
            Spec(host: 31, mac: "7a:3f:1e:92:c4:58", kind: .phone, mdns: n("Alexs-iPhone.local", "小林的iPhone.local"),
                 model: "iPhone 17 Pro", os: "iOS 27",
                 services: [("_companion-link._tcp", 49_153), ("_apple-mobdev2._tcp", 32_498)],
                 ports: [62_078], latency: 24, habit: .evenings, ipv6: ["fe80::8f1:c3ff:fe4a:2b17"]),
            Spec(host: 32, mac: "a6:12:9d:3b:07:e4", kind: .tablet, mdns: n("Family-iPad.local", "家里的iPad.local"),
                 model: "iPad Air (M3)", os: "iPadOS 27", services: [("_companion-link._tcp", 49_154)],
                 ports: [62_078], latency: 9, habit: .evenings),
            Spec(host: 40, mac: "88:66:5a:12:f0:3b", kind: .mediaPlayer, mdns: n("Living-Room.local", "客厅.local"),
                 model: "Apple TV 4K (3rd generation)", os: "tvOS 27",
                 services: [("_airplay._tcp", 7000), ("_raop._tcp", 7000), ("_companion-link._tcp", 49_155),
                            ("_mediaremotetv._tcp", 49_156), ("_sleep-proxy._udp", 50_301)],
                 ports: [7000, 7100, 49_152], latency: 4, favorite: true),
            Spec(host: 41, mac: "a4:83:e7:77:19:c4", kind: .speaker, mdns: n("Kitchen.local", "厨房.local"),
                 model: "HomePod mini", services: [("_airplay._tcp", 7000), ("_raop._tcp", 7000), ("_hap._tcp", 49_157)],
                 latency: 6),
            Spec(host: 42, mac: "48:a6:b8:0c:55:e1", kind: .speaker, name: n("Bedroom", "卧室"), model: "Sonos Era 100",
                 services: [("_sonos._tcp", 1443), ("_spotify-connect._tcp", 1400)], ports: [1400, 1443], latency: 8),
            Spec(host: 50, mac: "a8:23:fe:44:9b:20", kind: .tv, name: "[LG] webOS TV OLED65C4", model: "OLED65C4",
                 os: "webOS", services: [("_airplay._tcp", 7000), ("_hap._tcp", 49_158)], ports: [3000, 3001],
                 latency: 7, habit: .evenings, online: false, lastSeenHoursAgo: 9),
            Spec(host: 51, mac: "f4:f5:d8:3e:21:7a", kind: .mediaPlayer, name: n("Bedroom TV", "卧室电视"),
                 model: "Chromecast with Google TV", services: [("_googlecast._tcp", 8009)], ports: [8008, 8009],
                 latency: 12),
            Spec(host: 60, mac: "3c:d9:2b:6a:0e:55", kind: .printer, mdns: "HP-LaserJet-M404dn.local",
                 model: "HP LaserJet Pro M404dn",
                 services: [("_ipp._tcp", 631), ("_ipps._tcp", 443), ("_printer._tcp", 515), ("_pdl-datastream._tcp", 9100),
                            ("_http._tcp", 80)],
                 ports: [80, 443, 631, 9100], latency: 3),
            Spec(host: 70, mac: "bc:ad:28:91:3c:0f", kind: .camera, custom: n("Front Door Camera", "门口摄像头"),
                 model: "DS-2CD2043G2-I", ports: [80, 443, 554, 8000], latency: 5, watched: true),
            Spec(host: 80, mac: "00:17:88:6b:2a:11", kind: .smartHome, mdns: "Philips-hue.local", model: "Hue Bridge",
                 services: [("_hue._tcp", 443), ("_hap._tcp", 8080)], ports: [80, 443], latency: 3),
            Spec(host: 81, mac: "78:11:dc:4f:8a:20", kind: .smartHome, custom: n("Air Purifier", "空气净化器"),
                 dns: "zhimi-airp-mb5a_miio40125", model: "Mi Air Purifier 4", latency: 45),
            Spec(host: 90, mac: "d8:3a:dd:51:0e:93", kind: .server, mdns: "homeassistant.local", model: "Raspberry Pi 5",
                 os: "Home Assistant OS",
                 services: [("_home-assistant._tcp", 8123), ("_ssh._tcp", 22), ("_http._tcp", 8123)],
                 ports: [22, 8123], latency: 2, favorite: true),
            Spec(host: 101, mac: "00:d8:61:2c:77:e8", kind: .computer, netbios: "GAMING-PC", os: "Windows 11",
                 ports: [135, 139, 445, 3389], latency: 2.6, habit: .evenings),
            Spec(host: 120, mac: "98:b6:e9:30:6d:04", kind: .gameConsole, model: "Nintendo Switch 2", latency: 11,
                 habit: .sometimes, online: false, lastSeenHoursAgo: 52),
            Spec(host: 130, mac: "24:0a:c4:9e:13:57", kind: .iot, mdns: "esphome-garage-door.local",
                 model: "ESP32", services: [("_esphomelib._tcp", 6053)], ports: [6053], latency: 18,
                 firstSeenHoursAgo: 3),
            Spec(host: 144, mac: "5e:c1:07:a9:3d:f2", kind: .phone, dns: "Galaxy-S25", os: "Android", latency: 31,
                 firstSeenHoursAgo: 0.8),
        ]

        var random = SeededRandom(seed: 7)
        let gateway = IPv4Address(192, 168, 1, 1)
        let me = IPv4Address(192, 168, 1, 23)
        let devices = specs.map { spec -> Device in
            let mac = MACAddress(spec.mac)!
            let ip = IPv4Address(192, 168, 1, spec.host)
            let firstSeen = now.addingTimeInterval(-spec.firstSeenHoursAgo * 3600)
            var d = Device(id: Device.key(for: mac), mac: mac, ipv4: ip, now: firstSeen)
            d.ipv6 = spec.ipv6.compactMap(IPv6Address.init)
            if let full = OUIDatabase.shared.vendor(for: mac) {
                d.vendorFull = full
                d.vendor = OUIDatabase.shortName(full)
            }
            d.kind = spec.kind
            d.friendlyName = spec.name
            d.customName = spec.custom
            d.mdnsName = spec.mdns
            d.dnsName = spec.dns
            d.netbiosName = spec.netbios
            d.netbiosGroup = spec.netbios.map { _ in "WORKGROUP" }
            d.model = spec.model
            d.osName = spec.os
            d.services = spec.services.map { type, port in
                BonjourService(type: type, name: spec.name ?? spec.model ?? type, port: port, txt: [:])
            }
            d.openPorts = spec.ports
            d.portsScannedAt = spec.ports.isEmpty ? nil : now.addingTimeInterval(-86_400)
            d.isFavorite = spec.favorite
            d.isWatched = spec.watched
            d.isGateway = ip == gateway
            d.isCurrentDevice = ip == me
            d.isOnline = spec.online
            d.lastSeen = now.addingTimeInterval(-spec.lastSeenHoursAgo * 3600)
            d.latencyHistory = (0..<40).map { _ in max(0.1, spec.latency * random.next(in: 0.7...1.6)) }
            d.latency = spec.online ? d.latencyHistory.last : nil
            // A completed scan every two hours since the device was first seen.
            var date = max(firstSeen, now.addingTimeInterval(-14 * 86_400))
            while date < d.lastSeen {
                let hour = Calendar.current.component(.hour, from: date)
                let online = switch spec.habit {
                case .always: random.next(in: 0...1) > 0.02
                case .daytime: (8..<23).contains(hour) && random.next(in: 0...1) > 0.1
                case .evenings: !(9..<18).contains(hour) && random.next(in: 0...1) > 0.1
                case .sometimes: random.next(in: 0...1) > 0.75
                }
                d.presence.append(PresenceSample(date: date, online: online))
                date.addTimeInterval(2 * 3600)
            }
            d.presence.append(PresenceSample(date: d.lastSeen, online: true))
            if !spec.online { d.presence.append(PresenceSample(date: now.addingTimeInterval(-1800), online: false)) }
            return d
        }

        var publicIP = PublicIPInfo()
        publicIP.ipv4 = "203.0.113.42"
        publicIP.city = n("San Francisco", "上海")
        publicIP.country = n("United States", "中国")
        publicIP.countryCode = zh ? "CN" : "US"
        let interface = NetworkInterface(name: "en0", index: 1, displayName: "Wi-Fi", kind: .wifi,
                                         mac: MACAddress("f0:18:98:5c:2d:91"), ipv4: me,
                                         netmask: IPv4Address(255, 255, 255, 0), gateway: gateway,
                                         ipv6: [IPv6Address("fe80::1c2b:4a9f:e31d:7a02")!])
        return DemoNetwork(interface: interface, devices: devices, publicIP: publicIP, dnsServers: ["192.168.1.1"],
                           lastScan: ScanSummary(duration: 3.6, hostsProbed: 254, neighborSource: .sysctl),
                           lastScanDate: now.addingTimeInterval(-120))
    }
}

/// Repeatable pseudo-random numbers, so every screenshot run shows the same history.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return range.lowerBound + Double(state >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}
#endif
