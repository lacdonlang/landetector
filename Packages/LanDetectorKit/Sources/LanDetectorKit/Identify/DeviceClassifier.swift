import Foundation

public struct Identification: Sendable, Hashable {
    public var kind: DeviceKind = .unknown
    public var model: String?
    public var manufacturer: String?
    public var osName: String?
    public var friendlyName: String?
    /// 0…1, how sure the classifier is about `kind`.
    public var confidence: Double = 0
}

/// Multi-signal device identification: every signal casts weighted votes for a kind, and
/// model / manufacturer / OS are taken from the most authoritative source available.
public enum DeviceClassifier {
    public static func identify(_ d: Device) -> Identification {
        var votes: [DeviceKind: Double] = [:]
        /// Order in which kinds got their first vote; signals are checked from most to least authoritative.
        var firstVote: [DeviceKind: Int] = [:]
        var result = Identification()
        func vote(_ kind: DeviceKind, _ weight: Double) {
            votes[kind, default: 0] += weight
            if firstVote[kind] == nil { firstVote[kind] = firstVote.count }
        }

        let txt = TXTIndex(d.services)

        // 1. Apple model identifiers carried in Bonjour TXT records.
        var appleIdentifier: String? = txt.value("_device-info._tcp", "model")
        if appleIdentifier == nil { appleIdentifier = txt.value("_companion-link._tcp", "rpmd") }
        if appleIdentifier == nil, let m = txt.value("_airplay._tcp", "model"), m.contains(",") { appleIdentifier = m }
        if appleIdentifier == nil, let m = txt.value("_raop._tcp", "am"), m.contains(",") { appleIdentifier = m }
        if appleIdentifier == nil, d.isCurrentDevice { appleIdentifier = LocalMachine.modelIdentifier }
        if let identifier = appleIdentifier, let (kind, name) = appleModel(identifier) {
            vote(kind, 10)
            result.model = name
            result.manufacturer = "Apple"
            result.osName = appleOS(kind, identifier: identifier)
        }

        // 2. Other TXT based identification.
        if let md = txt.value("_googlecast._tcp", "md") {
            result.model = result.model ?? md
            let lower = md.lowercased()
            if lower.contains("mini") || lower.contains("home") || lower.contains("audio") || lower.contains("speaker") {
                vote(.speaker, 6)
            } else if lower.contains("hub") {
                vote(.smartHome, 6)
            } else if lower.contains("tv") || lower.contains("bravia") {
                vote(.tv, 6)
            } else {
                vote(.mediaPlayer, 6)
            }
            result.manufacturer = result.manufacturer ?? (lower.contains("chromecast") || lower.contains("google") || lower.contains("nest") ? "Google" : nil)
        }
        if let airplayModel = txt.value("_airplay._tcp", "model"), !airplayModel.contains(","), appleIdentifier == nil {
            result.model = result.model ?? airplayModel
            result.manufacturer = result.manufacturer ?? txt.value("_airplay._tcp", "manufacturer")
            vote(.tv, 3)
        }
        if let printer = txt.value(anyOf: ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp"], key: "ty")
            ?? txt.value(anyOf: ["_ipp._tcp", "_ipps._tcp", "_printer._tcp"], key: "product")?
                .trimmingCharacters(in: CharacterSet(charactersIn: "()")) {
            vote(.printer, 9)
            result.model = result.model ?? printer
        }
        if let hapModel = txt.value("_hap._tcp", "md") ?? txt.value("_hap._udp", "md") {
            result.model = result.model ?? hapModel
            vote(hapKind(txt.value("_hap._tcp", "ci") ?? txt.value("_hap._udp", "ci")), 5)
        }
        if let mn = txt.value("_meshcop._udp", "mn") {
            result.model = result.model ?? mn
            result.manufacturer = result.manufacturer ?? txt.value("_meshcop._udp", "vn")
        }

        // 3. Service presence.
        for service in d.services {
            if let (kind, weight) = serviceHints[service.type] { vote(kind, weight) }
        }

        // 4. UPnP description.
        if let upnp = d.upnp {
            let type = upnp.deviceType?.lowercased() ?? ""
            let maker = upnp.manufacturer?.lowercased() ?? ""
            if type.contains("internetgatewaydevice") || type.contains("wandevice") || type.contains("wfadevice") {
                vote(.router, 6)
            } else if type.contains("mediarenderer") {
                vote(["sonos", "bose", "denon", "marantz", "yamaha", "harman", "bang"].contains { maker.contains($0) } ? .speaker : .tv, 4)
            } else if type.contains("mediaserver") {
                vote(.nas, 2)
            } else if type.contains("printer") {
                vote(.printer, 6)
            } else if type.contains("camera") || type.contains("security") {
                vote(.camera, 6)
            }
            if let name = upnp.modelName {
                let modelText = [upnp.modelName, upnp.modelNumber].compactMap { $0 }.joined(separator: " ")
                if result.model == nil, !name.isEmpty { result.model = modelText }
                classifyText(modelText.lowercased(), weight: 4, vote: vote)
            }
            if result.manufacturer == nil, let m = upnp.manufacturer { result.manufacturer = OUIDatabase.shortName(m) }
            if let server = upnp.server?.lowercased(), result.osName == nil {
                if server.contains("linux") { result.osName = "Linux" } else if server.contains("windows") { result.osName = "Windows" }
            }
        }

        // 5. NetBIOS: Windows or Samba.
        if d.netbiosName != nil {
            vote(.computer, 2)
            if result.osName == nil {
                result.osName = d.openPorts.contains(135) || d.openPorts.contains(3389) ? "Windows" : nil
            }
        }

        // 6. Host name patterns.
        let hostNames: [String?] = [d.mdnsName, d.netbiosName, d.dnsName, d.friendlyName]
        for name in hostNames.compactMap({ $0?.lowercased() }) {
            classifyText(name, weight: 3, vote: vote)
        }

        // 7. Vendor.
        if let vendor = d.vendorFull?.lowercased() {
            for (pattern, kind, weight) in vendorHints where vendor.contains(pattern) {
                vote(kind, weight)
                break
            }
        }
        if result.manufacturer == nil, let vendor = d.vendor { result.manufacturer = vendor }

        // 8. Open ports.
        let ports = Set(d.openPorts)
        for (port, kind, weight) in portHints where ports.contains(port) { vote(kind, weight) }
        if ports.contains(135) && ports.contains(445) { vote(.computer, 3); result.osName = result.osName ?? "Windows" }
        if ports.contains(62078) { result.osName = result.osName ?? "iOS" }
        if ports == [22] { vote(.server, 1.5) }

        // 9. Service banners (HTTP titles, SSH greetings…).
        if !d.banners.isEmpty {
            let text = d.banners.values.joined(separator: " ").lowercased()
            classifyText(text, weight: 2.5, vote: vote)
            for (keyword, kind, os, weight) in bannerHints where text.contains(keyword) {
                if let kind { vote(kind, weight) }
                if let os, result.osName == nil { result.osName = os }
            }
        }

        // 10. Private (randomised) MAC with nothing else: almost always a phone/tablet/watch.
        if d.hasPrivateMAC && votes.isEmpty { vote(.phone, 1) }

        // 11. Gateway / this Mac.
        if d.isGateway { vote(.router, 20) }
        if d.isCurrentDevice, votes[.laptop] == nil && votes[.computer] == nil { vote(.computer, 5) }

        // Apple devices that only reveal themselves through their host name ("Johns-iPhone").
        if result.model == nil, (d.vendorFull?.lowercased().hasPrefix("apple") ?? false) || d.hasPrivateMAC {
            let names = hostNames.compactMap { $0?.lowercased() }.joined(separator: " ")
            for (keyword, model) in [("iphone", "iPhone"), ("ipad", "iPad"), ("macbook-air", "MacBook Air"),
                                     ("macbook-pro", "MacBook Pro"), ("macbook", "MacBook"), ("imac", "iMac"),
                                     ("mac-mini", "Mac mini"), ("mac-studio", "Mac Studio"), ("apple-tv", "Apple TV"),
                                     ("homepod", "HomePod"), ("apple-watch", "Apple Watch")] where names.contains(keyword) {
                result.model = model
                result.manufacturer = "Apple"
                break
            }
        }

        // Pick the winner. A tie goes to the kind the earlier, more authoritative signal voted for – not to whatever
        // the dictionary happens to list last.
        if let (kind, score) = votes.max(by: { a, b in
            a.value != b.value ? a.value < b.value : firstVote[a.key, default: 0] > firstVote[b.key, default: 0]
        }) {
            result.kind = kind
            let total = votes.values.reduce(0, +)
            result.confidence = min(1, score / 10) * (score / max(total, 0.001))
        }

        // OS hints from names and services.
        if result.osName == nil {
            if d.services.contains(where: { $0.type == "_workstation._tcp" }) { result.osName = "Linux" }
            let nameList: [String?] = [d.mdnsName, d.dnsName, d.netbiosName]
            let names = nameList.compactMap { $0?.lowercased() }.joined(separator: " ")
            if names.contains("android") || names.contains("galaxy") || names.contains("pixel") { result.osName = "Android" }
        }

        result.friendlyName = friendlyName(d, txt: txt)
        return result
    }

    // MARK: - Friendly names

    private static func friendlyName(_ d: Device, txt: TXTIndex) -> String? {
        var candidates: [String?] = [
            txt.value("_googlecast._tcp", "fn"),
            d.services.first(where: { $0.type == "_companion-link._tcp" })?.name,
            d.services.first(where: { $0.type == "_airplay._tcp" })?.name,
            d.services.first(where: { $0.type == "_raop._tcp" })?.name.split(separator: "@", maxSplits: 1).last.map(String.init),
            txt.value("_amzn-wplay._tcp", "n"),
            d.services.first(where: { $0.type == "_hap._tcp" })?.name,
            d.services.first(where: { $0.type == "_sonos._tcp" })?.name,
            d.services.first(where: { $0.type == "_spotify-connect._tcp" })?.name,
        ]
        if let upnpName = d.upnp?.friendlyName { candidates.append(upnpName) }
        for c in candidates {
            guard let name = c?.trimmingCharacters(in: .whitespaces), isHumanName(name) else { continue }
            return name
        }
        return nil
    }

    /// Rejects UUIDs, MAC-like strings and other machine identifiers.
    static func isHumanName(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 64 else { return false }
        let hexish = s.filter { $0.isHexDigit || $0 == "-" || $0 == ":" }
        if Double(hexish.count) / Double(s.count) > 0.85 && s.count >= 12 { return false }
        if s.hasPrefix("RINCON_") || s.lowercased().hasPrefix("uuid") { return false }
        return true
    }

    // MARK: - Apple

    static func appleModel(_ identifier: String) -> (DeviceKind, String)? {
        if let m = AppleModelDatabase.shared.model(for: identifier) {
            return (appleKind(family: m.family, identifier: identifier), m.name)
        }
        // Unknown (newer) identifiers: infer from the prefix.
        let kind = appleKind(family: "", identifier: identifier)
        guard kind != .unknown else { return nil }
        return (kind, identifier)
    }

    static func appleKind(family: String, identifier: String) -> DeviceKind {
        let f = family.lowercased(), id = identifier.lowercased()
        if f.hasPrefix("iphone") || id.hasPrefix("iphone") || f == "ipod touch" || id.hasPrefix("ipod") { return .phone }
        if f.hasPrefix("ipad") || id.hasPrefix("ipad") { return .tablet }
        if f.contains("watch") || id.hasPrefix("watch") { return .watch }
        if f == "apple tv" || id.hasPrefix("appletv") { return .mediaPlayer }
        if f == "homepod" || id.hasPrefix("audioaccessory") { return .speaker }
        if f.hasPrefix("macbook") || id.hasPrefix("macbook") { return .laptop }
        if ["imac", "mac mini", "mac pro", "mac studio", "xserve"].contains(f) || id.hasPrefix("imac")
            || id.hasPrefix("macmini") || id.hasPrefix("macpro") || id.hasPrefix("mac") { return .computer }
        if f == "airport" || id.hasPrefix("airport") { return .router }
        if f == "virtual machine" || id.hasPrefix("vmware") { return .virtualMachine }
        return .unknown
    }

    static func appleOS(_ kind: DeviceKind, identifier: String) -> String? {
        switch kind {
        case .phone: "iOS"
        case .tablet: "iPadOS"
        case .watch: "watchOS"
        case .mediaPlayer: "tvOS"
        case .speaker: "audioOS"
        case .laptop, .computer: "macOS"
        default: nil
        }
    }

    // MARK: - Rules

    static func hapKind(_ category: String?) -> DeviceKind {
        switch Int(category ?? "") {
        case 17, 18: .camera
        case 31: .tv
        default: .smartHome
        }
    }

    static let serviceHints: [String: (DeviceKind, Double)] = [
        "_printer._tcp": (.printer, 6), "_ipp._tcp": (.printer, 6), "_ipps._tcp": (.printer, 6),
        "_pdl-datastream._tcp": (.printer, 6), "_scanner._tcp": (.printer, 3), "_uscan._tcp": (.printer, 3),
        "_googlecast._tcp": (.mediaPlayer, 3), "_amzn-wplay._tcp": (.mediaPlayer, 6),
        "_androidtvremote2._tcp": (.tv, 6), "_viziocast._tcp": (.tv, 6), "_mediaremotetv._tcp": (.mediaPlayer, 5),
        "_sonos._tcp": (.speaker, 7), "_spotify-connect._tcp": (.speaker, 1.5), "_raop._tcp": (.speaker, 1.5),
        "_tidalconnect._tcp": (.speaker, 2), "_beocore._tcp": (.speaker, 5), "_netaudio-chan._udp": (.speaker, 3),
        "_hap._tcp": (.smartHome, 4), "_hap._udp": (.smartHome, 4), "_matter._tcp": (.smartHome, 3),
        "_matterc._udp": (.smartHome, 3), "_hue._tcp": (.smartHome, 6), "_esphomelib._tcp": (.iot, 6),
        "_shelly._tcp": (.iot, 6), "_wled._tcp": (.iot, 6), "_nanoleafapi._tcp": (.smartHome, 6),
        "_elg._tcp": (.smartHome, 4), "_miio._udp": (.smartHome, 4), "_axis-video._tcp": (.camera, 8),
        "_rtsp._tcp": (.camera, 3), "_psia._tcp": (.camera, 6), "_home-assistant._tcp": (.server, 6),
        "_plexmediasvr._tcp": (.server, 3), "_qdiscover._tcp": (.nas, 8), "_adisk._tcp": (.nas, 2),
        "_smb._tcp": (.computer, 1), "_afpovertcp._tcp": (.computer, 1), "_rfb._tcp": (.computer, 3),
        "_ssh._tcp": (.computer, 1), "_sftp-ssh._tcp": (.computer, 1), "_workstation._tcp": (.computer, 2),
        "_nvstream._tcp": (.computer, 4), "_airport._tcp": (.router, 8), "_apple-mobdev2._tcp": (.phone, 3),
        "_companion-link._tcp": (.phone, 0.5), "_sleep-proxy._udp": (.mediaPlayer, 1),
        "_meshcop._udp": (.smartHome, 2), "_mqtt._tcp": (.server, 2),
    ]

    /// (keyword in banners, kind, OS, weight).
    static let bannerHints: [(String, DeviceKind?, String?, Double)] = [
        ("openwrt", .router, "OpenWrt", 4), ("raspbian", .server, "Raspberry Pi OS", 2),
        ("routeros", .router, "RouterOS", 5), ("mikrotik", .router, "RouterOS", 4),
        ("synology", .nas, "Synology DSM", 6), ("diskstation", .nas, "Synology DSM", 6), ("qnap", .nas, "QTS", 6),
        ("truenas", .nas, "TrueNAS", 6), ("unraid", .nas, "Unraid", 6), ("proxmox", .server, "Proxmox VE", 6),
        ("esxi", .server, "VMware ESXi", 6), ("pi-hole", .server, "Linux", 4), ("home assistant", .server, nil, 5),
        ("plex", .server, nil, 3), ("unifi", .networkDevice, nil, 4), ("h3c", .networkDevice, nil, 3),
        ("hikvision", .camera, nil, 5), ("dahua", .camera, nil, 5), ("ipcam", .camera, nil, 4),
        ("laserjet", .printer, nil, 5), ("officejet", .printer, nil, 5), ("printer", .printer, nil, 3),
        ("microsoft-iis", nil, "Windows", 0), ("microsoft-httpapi", nil, "Windows", 0), ("rfb 003", .computer, nil, 1),
        ("asus router", .router, nil, 5), ("tp-link", .router, nil, 2), ("netgear", .router, nil, 2),
        ("fritz!box", .router, "FRITZ!OS", 6), ("pfsense", .router, "pfSense", 6), ("opnsense", .router, "OPNsense", 6),
        // Generic hints last: the first matching OS wins.
        ("ubuntu", nil, "Ubuntu Linux", 0), ("debian", nil, "Debian Linux", 0), ("freebsd", nil, "FreeBSD", 0),
        ("dropbear", nil, "Linux（嵌入式）", 0),
    ]

    static let portHints: [(UInt16, DeviceKind, Double)] = [
        (9100, .printer, 5), (631, .printer, 3), (515, .printer, 3), (554, .camera, 3), (37777, .camera, 6),
        (34567, .camera, 6), (8000, .camera, 0.5), (62078, .phone, 4), (3389, .computer, 4), (548, .computer, 1.5),
        (8009, .mediaPlayer, 3), (8008, .mediaPlayer, 1), (8060, .mediaPlayer, 6), (1400, .speaker, 5),
        (32400, .server, 3), (8123, .server, 5), (5555, .tv, 2), (6668, .iot, 5), (1883, .server, 1.5),
        (5000, .nas, 0.5), (5001, .nas, 1.5), (2375, .server, 3), (6443, .server, 3), (8291, .router, 6),
        (53, .router, 1.5), (7547, .router, 3), (902, .server, 3), (5900, .computer, 1.5), (3306, .server, 1.5),
        (5432, .server, 1.5),
    ]

    /// (substring of full IEEE organisation name, kind, weight) – first match wins.
    static let vendorHints: [(String, DeviceKind, Double)] = [
        ("vmware", .virtualMachine, 5), ("parallels", .virtualMachine, 5), ("xensource", .virtualMachine, 5),
        ("proxmox", .virtualMachine, 5), ("espressif", .iot, 4), ("tuya", .iot, 4), ("shelly", .iot, 4),
        ("allterco", .iot, 4), ("bouffalo", .iot, 4), ("silicon lab", .iot, 3), ("nordic semi", .iot, 3),
        ("raspberry pi", .server, 3), ("synology", .nas, 5), ("qnap", .nas, 5), ("western digital", .nas, 3),
        ("asustor", .nas, 5), ("terramaster", .nas, 5), ("hikvision", .camera, 5), ("dahua", .camera, 5),
        ("reolink", .camera, 5), ("axis comm", .camera, 5), ("ezviz", .camera, 5), ("wyze", .camera, 4),
        ("uniview", .camera, 5), ("ring llc", .camera, 4), ("sonos", .speaker, 5), ("bose", .speaker, 4),
        ("harman", .speaker, 3), ("denon", .speaker, 4), ("marantz", .speaker, 4), ("bang & olufsen", .speaker, 4),
        ("roku", .mediaPlayer, 5), ("nintendo", .gameConsole, 5), ("sony interactive", .gameConsole, 5),
        ("valve", .gameConsole, 3), ("signify", .smartHome, 5), ("philips lighting", .smartHome, 5),
        ("ikea", .smartHome, 4), ("ecobee", .smartHome, 5), ("nest labs", .smartHome, 4), ("lumi united", .smartHome, 4),
        ("yeelink", .smartHome, 4), ("lutron", .smartHome, 4), ("irobot", .smartHome, 4), ("roborock", .smartHome, 4),
        ("ecovacs", .smartHome, 4), ("dyson", .smartHome, 4), ("withings", .smartHome, 3), ("midea", .smartHome, 3),
        ("gree electric", .smartHome, 3), ("haier", .smartHome, 2), ("ubiquiti", .networkDevice, 3),
        ("mikrotik", .networkDevice, 3), ("routerboard", .networkDevice, 3), ("juniper", .networkDevice, 3),
        ("aruba", .networkDevice, 3), ("ruijie", .networkDevice, 3), ("h3c", .networkDevice, 3),
        ("zyxel", .networkDevice, 2), ("tenda", .networkDevice, 2), ("eero", .networkDevice, 4),
        ("plume design", .networkDevice, 4), ("tp-link", .networkDevice, 1), ("netgear", .networkDevice, 1.5),
        ("d-link", .networkDevice, 1.5), ("linksys", .networkDevice, 2), ("cisco", .networkDevice, 2),
        ("arcadyan", .networkDevice, 2), ("sagemcom", .networkDevice, 2), ("technicolor", .networkDevice, 2),
        ("sercomm", .networkDevice, 2), ("arris", .networkDevice, 2), ("avm", .networkDevice, 2),
        ("brother", .printer, 4), ("seiko epson", .printer, 4), ("canon", .printer, 2), ("lexmark", .printer, 4),
        ("kyocera", .printer, 4), ("xerox", .printer, 3), ("ricoh", .printer, 3),
        ("tcl", .tv, 2), ("hisense", .tv, 3), ("vizio", .tv, 3), ("garmin", .watch, 2), ("fitbit", .watch, 3),
        ("intel corporate", .laptop, 1), ("azurewave", .laptop, 1), ("liteon", .laptop, 1), ("lite-on", .laptop, 1),
        ("dell", .computer, 1.5), ("lenovo", .computer, 1), ("micro-star", .computer, 2), ("asrock", .computer, 2),
        ("giga-byte", .computer, 2), ("super micro", .server, 3), ("xiaomi", .phone, 0.8), ("huawei", .phone, 0.5),
        ("honor device", .phone, 1), ("guangdong oppo", .phone, 1.5), ("vivo mobile", .phone, 1.5),
        ("oneplus", .phone, 1.5), ("motorola mobility", .phone, 1.5), ("amazon", .speaker, 1),
    ]

    /// Keyword rules for host names and model strings.
    static func classifyText(_ text: String, weight: Double, vote: (DeviceKind, Double) -> Void) {
        for (keywords, kind) in textRules where keywords.contains(where: { text.contains($0) }) {
            vote(kind, weight)
            return
        }
    }

    static let textRules: [([String], DeviceKind)] = [
        (["iphone"], .phone), (["ipad"], .tablet), (["macbook", "-mbp", "mbp-"], .laptop),
        (["imac", "mac-mini", "macmini", "mac-studio", "macstudio", "mac-pro"], .computer),
        (["apple-tv", "appletv"], .mediaPlayer), (["homepod"], .speaker), (["apple-watch", "applewatch"], .watch),
        (["chromecast", "googlecast", "fire-tv", "firetv", "fire tv", "roku", "shield", "mibox", "mi box"], .mediaPlayer),
        (["bravia", "lgwebostv", "webos", "tizen", "samsung-tv", "samsungtv", "smart-tv", "smarttv", "androidtv",
          "android-tv", "-tv", "tv-"], .tv),
        (["echo", "alexa", "sonos", "nest-mini", "nestmini", "nest-audio", "google-home", "googlehome", "soundbar",
          "speaker", "xiaoai", "小爱"], .speaker),
        (["nest-hub", "nesthub", "thermostat", "ecobee", "vacuum", "roborock", "roomba", "dreame", "hue-bridge",
          "philips-hue", "homey", "smartthings", "aqara", "gateway-zigbee"], .smartHome),
        // Xiaomi ecosystem (MIoT) host names: "zhimi-airp-sa4_mibtAC1B", "chuangmi-plug-v3_miio123456".
        (["_miio", "_mibt", "zhimi-", "chuangmi-", "yeelink-", "lumi-", "dmaker-", "viomi-", "mijia"], .smartHome),
        (["doorbell", "ipcam", "ip-cam", "camera", "-cam", "cam-", "hikvision", "dahua", "reolink", "ezviz", "wyze",
          "blink", "arlo"], .camera),
        (["printer", "laserjet", "officejet", "deskjet", "envy", "epson", "brother", "canon", "mfc-", "hl-", "ecotank",
          "pixma"], .printer),
        (["synology", "diskstation", "rackstation", "qnap", "truenas", "freenas", "unraid", "nas-", "-nas", "omv"], .nas),
        (["xbox", "playstation", "ps4", "ps5", "nintendo", "switch-", "steamdeck", "steam-deck"], .gameConsole),
        (["tab-", "galaxy-tab", "matepad", "-pad", "kindle"], .tablet),
        (["android", "galaxy", "pixel", "redmi", "xiaomi", "huawei", "honor", "oneplus", "oppo", "vivo", "sm-g",
          "sm-s", "sm-a", "realme", "poco", "phone"], .phone),
        (["watch"], .watch),
        (["laptop", "notebook", "thinkpad", "zenbook", "vivobook", "xps", "surface"], .laptop),
        (["desktop-", "win-", "pc-", "-pc", "workstation"], .computer),
        (["proxmox", "pve", "esxi", "server", "srv-", "docker", "k8s", "kube", "homeassistant", "home-assistant",
          "hassio", "pihole", "pi-hole", "raspberrypi", "raspberry"], .server),
        (["esp32", "esp8266", "esp-", "espressif", "tasmota", "shelly", "sonoff", "tuya", "wled", "esphome", "plug",
          "bulb", "light", "switch"], .iot),
        (["router", "openwrt", "asusrouter", "archer", "tplink", "mikrotik", "unifi", "udm", "ubnt", "eero", "orbi",
          "deco", "fritz", "gateway", "airport"], .router),
        (["access-point", "accesspoint", "-ap-", "switch", "mesh"], .networkDevice),
        (["vm-", "-vm", "virtual"], .virtualMachine),
    ]
}

/// Indexes TXT dictionaries by service type.
struct TXTIndex {
    private var byType: [String: [String: String]] = [:]

    init(_ services: [BonjourService]) {
        for s in services {
            byType[s.type, default: [:]].merge(s.txt) { old, _ in old }
        }
    }

    func value(_ type: String, _ key: String) -> String? {
        guard let v = byType[type]?[key], !v.isEmpty else { return nil }
        return v
    }

    func value(anyOf types: [String], key: String) -> String? {
        for t in types { if let v = value(t, key) { return v } }
        return nil
    }
}

/// Facts about the Mac running the app.
public enum LocalMachine {
    public static let modelIdentifier: String? = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cChars: buffer)
    }()

    public static var hostName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
}
