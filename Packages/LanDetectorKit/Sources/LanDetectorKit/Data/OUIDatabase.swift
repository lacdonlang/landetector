import Foundation

/// Locates bundled data files, preferring user-updated copies in Application Support.
public enum DataFiles {
    public static var userDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LanDetector/Data", isDirectory: true)
    }

    public static func url(_ name: String, _ ext: String) -> URL? {
        let user = userDirectory.appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: user.path) { return user }
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }

    /// Iterates tab separated lines without building intermediate strings for the whole file.
    static func forEachLine(_ url: URL?, _ body: ([Substring]) -> Void) {
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            body(line.split(separator: "\t", omittingEmptySubsequences: false))
        }
    }
}

/// IEEE MA-L / MA-M / MA-S / IAB / CID vendor lookup.
public final class OUIDatabase: Sendable {
    public static let shared = OUIDatabase()

    private let blocks24: [UInt32: String]
    private let blocks28: [UInt32: String]
    private let blocks36: [UInt64: String]
    public let count: Int

    public init(url: URL? = DataFiles.url("oui", "tsv")) {
        var b24: [UInt32: String] = [:], b28: [UInt32: String] = [:], b36: [UInt64: String] = [:]
        b24.reserveCapacity(42_000)
        DataFiles.forEachLine(url) { cols in
            guard cols.count >= 2, let value = UInt64(cols[0], radix: 16) else { return }
            let name = String(cols[1])
            switch cols[0].count {
            case 6: b24[UInt32(value)] = name
            case 7: b28[UInt32(value)] = name
            case 9: b36[value] = name
            default: break
            }
        }
        blocks24 = b24
        blocks28 = b28
        blocks36 = b36
        count = b24.count + b28.count + b36.count
    }

    /// Full registered organisation name, longest prefix first.
    public func vendor(for mac: MACAddress) -> String? {
        if let v = blocks36[mac.prefix(bits: 36)] { return v }
        if let v = blocks28[UInt32(mac.prefix(bits: 28))] { return v }
        return blocks24[UInt32(mac.prefix(bits: 24))]
    }

    /// Compact brand name for tables ("Apple, Inc." → "Apple").
    public static func shortName(_ full: String) -> String {
        let lower = full.lowercased()
        for (prefix, alias) in aliases where lower.hasPrefix(prefix) { return alias }
        var words = full.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        while words.count > 1, let last = words.last,
              suffixes.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".()"))) {
            words.removeLast()
        }
        var result = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))
        if result.count > 4, result == result.uppercased(), result.rangeOfCharacter(from: .lowercaseLetters) == nil {
            result = result.capitalized
        }
        return result.isEmpty ? full : result
    }

    private static let suffixes: Set<String> = [
        "inc", "incorporated", "corporation", "corp", "co", "company", "ltd", "limited", "llc", "l.l.c", "gmbh",
        "ag", "s.a", "sa", "s.r.l", "srl", "b.v", "bv", "oy", "ab", "as", "a/s", "kk", "k.k", "pty", "plc", "co.ltd",
        "co.,ltd", "ltda", "s.p.a", "spa", "sas", "nv", "technologies", "technology", "tech", "electronics",
        "electronic", "international", "communications", "communication", "industrial", "industries", "group",
        "holdings", "systems", "networks", "network", "intelligent", "digital", "products", "manufacturing",
        "precision", "ind", "devices", "device", "trading", "global", "solutions", "telecom", "information",
        "science", "&",
    ]

    private static let aliases: [(String, String)] = [
        ("apple", "Apple"), ("samsung", "Samsung"), ("hon hai", "Foxconn"), ("foxconn", "Foxconn"),
        ("cloud network technology", "Foxconn"), ("murata", "Murata"), ("intel corporate", "Intel"),
        ("intel", "Intel"), ("amazon", "Amazon"), ("google", "Google"), ("nest labs", "Google Nest"),
        ("tp-link", "TP-Link"), ("huawei", "Huawei"), ("honor device", "Honor"), ("xiaomi", "Xiaomi"),
        ("beijing xiaomi", "Xiaomi"), ("espressif", "Espressif"), ("raspberry pi", "Raspberry Pi"),
        ("sonos", "Sonos"), ("netgear", "Netgear"), ("asustek", "ASUS"), ("d-link", "D-Link"),
        ("ubiquiti", "Ubiquiti"), ("cisco", "Cisco"), ("microsoft", "Microsoft"), ("nintendo", "Nintendo"),
        ("sony interactive", "PlayStation"), ("sony", "Sony"), ("lg electronics", "LG"), ("lg innotek", "LG"),
        ("hewlett packard enterprise", "HPE"), ("hewlett packard", "HP"), ("hp inc", "HP"), ("dell", "Dell"),
        ("lenovo", "Lenovo"), ("realtek", "Realtek"), ("azurewave", "AzureWave"), ("liteon", "Lite-On"),
        ("lite-on", "Lite-On"), ("oneplus", "OnePlus"), ("guangdong oppo", "OPPO"), ("vivo mobile", "vivo"),
        ("zte", "ZTE"), ("new h3c", "H3C"), ("ruijie", "Ruijie"), ("synology", "Synology"), ("qnap", "QNAP"),
        ("western digital", "Western Digital"), ("hangzhou hikvision", "Hikvision"), ("zhejiang dahua", "Dahua"),
        ("tuya", "Tuya"), ("roku", "Roku"), ("belkin", "Belkin"), ("signify", "Philips Hue"),
        ("philips lighting", "Philips Hue"), ("philips", "Philips"), ("bose", "Bose"), ("brother", "Brother"),
        ("seiko epson", "Epson"), ("canon", "Canon"), ("texas instruments", "Texas Instruments"),
        ("nvidia", "NVIDIA"), ("vmware", "VMware"), ("parallels", "Parallels"), ("proxmox", "Proxmox"),
        ("xensource", "Xen"), ("arcadyan", "Arcadyan"), ("sagemcom", "Sagemcom"), ("technicolor", "Technicolor"),
        ("aruba", "Aruba"), ("mikrotik", "MikroTik"), ("routerboard", "MikroTik"), ("juniper", "Juniper"),
        ("fortinet", "Fortinet"), ("ecobee", "ecobee"), ("ring llc", "Ring"), ("wyze", "Wyze"),
        ("allterco", "Shelly"), ("shelly", "Shelly"), ("ikea", "IKEA"), ("motorola", "Motorola"),
        ("nokia", "Nokia"), ("tcl", "TCL"), ("hisense", "Hisense"), ("vizio", "Vizio"), ("panasonic", "Panasonic"),
        ("sharp", "Sharp"), ("toshiba", "Toshiba"), ("fujitsu", "Fujitsu"), ("giga-byte", "Gigabyte"),
        ("gigabyte", "Gigabyte"), ("micro-star", "MSI"), ("asrock", "ASRock"), ("super micro", "Supermicro"),
        ("zyxel", "Zyxel"), ("tenda", "Tenda"), ("bouffalo", "Bouffalo Lab"), ("silicon laboratories", "Silicon Labs"),
        ("silicon labs", "Silicon Labs"), ("nordic semiconductor", "Nordic"), ("amlogic", "Amlogic"),
        ("rockchip", "Rockchip"), ("allwinner", "Allwinner"), ("mediatek", "MediaTek"), ("qualcomm", "Qualcomm"),
        ("broadcom", "Broadcom"), ("garmin", "Garmin"), ("fitbit", "Fitbit"), ("dyson", "Dyson"),
        ("irobot", "iRobot"), ("beijing roborock", "Roborock"), ("roborock", "Roborock"), ("ecovacs", "Ecovacs"),
        ("midea", "Midea"), ("gree electric", "Gree"), ("haier", "Haier"), ("valve", "Valve"),
        ("meta platforms", "Meta"), ("oculus", "Meta"), ("peloton", "Peloton"), ("tesla", "Tesla"),
        ("chongqing fugui", "Foxconn"), ("universal global scientific", "USI"), ("wistron", "Wistron"),
        ("compal", "Compal"), ("quanta", "Quanta"), ("pegatron", "Pegatron"), ("inventec", "Inventec"),
        ("ampak", "AMPAK"), ("arris", "ARRIS"), ("commscope", "CommScope"), ("eero", "eero"),
        ("plume design", "Plume"), ("linksys", "Linksys"), ("buffalo", "Buffalo"), ("avm audiovisuelles", "AVM"),
        ("avm gmbh", "AVM"), ("sercomm", "Sercomm"), ("askey", "Askey"), ("gemtek", "Gemtek"),
        ("shenzhen bilian", "LB-Link"), ("ezviz", "EZVIZ"), ("reolink", "Reolink"), ("axis communications", "Axis"),
        ("logitech", "Logitech"), ("harman", "Harman"), ("denon", "Denon"), ("marantz", "Marantz"),
        ("yamaha", "Yamaha"), ("bang & olufsen", "Bang & Olufsen"), ("onkyo", "Onkyo"), ("pioneer", "Pioneer"),
        ("lutron", "Lutron"), ("crestron", "Crestron"), ("control4", "Control4"), ("ezlo", "Ezlo"),
        ("withings", "Withings"), ("anker", "Anker"), ("xiaomi communications", "Xiaomi"),
        ("lumi united", "Aqara"), ("aqara", "Aqara"), ("yeelight", "Yeelight"), ("qingdao yeelink", "Yeelight"),
        ("gd midea", "Midea"), ("hui zhou gaoshengda", "Gaoshengda"), ("zhejiang uniview", "Uniview"),
    ]
}

/// TCP service names from the IANA registry plus LAN-specific hints.
public final class PortDatabase: Sendable {
    public static let shared = PortDatabase()

    public struct Service: Sendable, Hashable {
        public let name: String
        public let description: String
    }

    private let services: [UInt16: Service]

    public init(url: URL? = DataFiles.url("ports", "tsv")) {
        var map: [UInt16: Service] = [:]
        DataFiles.forEachLine(url) { cols in
            guard cols.count >= 3, let port = UInt16(cols[0]) else { return }
            map[port] = Service(name: String(cols[1]), description: String(cols[2]))
        }
        for (port, hint) in Self.lanHints {
            map[port] = Service(name: hint.0, description: hint.1)
        }
        services = map
    }

    public func service(for port: UInt16) -> Service? { services[port] }

    public func label(for port: UInt16) -> String {
        guard let s = services[port] else { return "\(port)" }
        return "\(port) \(s.name)"
    }

    /// Ports whose meaning on a home/office LAN differs from (or is missing in) the IANA registry.
    static let lanHints: [UInt16: (String, String)] = [
        21: ("ftp", "FTP 文件传输"), 22: ("ssh", "SSH 远程登录"), 23: ("telnet", "Telnet"), 25: ("smtp", "SMTP 邮件"),
        53: ("dns", "DNS 域名解析"), 80: ("http", "HTTP 网页"), 88: ("kerberos", "Kerberos"),
        110: ("pop3", "POP3 邮件"), 111: ("rpcbind", "RPC 端口映射"), 135: ("msrpc", "Windows RPC"),
        139: ("netbios-ssn", "NetBIOS 会话 (SMB)"), 143: ("imap", "IMAP 邮件"), 443: ("https", "HTTPS 网页"),
        445: ("smb", "SMB 文件共享"), 515: ("printer", "LPD 打印"), 548: ("afp", "AFP 文件共享"),
        554: ("rtsp", "RTSP 视频流"), 631: ("ipp", "IPP 打印"), 873: ("rsync", "rsync 同步"),
        1080: ("socks", "SOCKS 代理"), 1400: ("sonos", "Sonos 控制"), 1883: ("mqtt", "MQTT 消息"),
        1900: ("upnp", "UPnP / SSDP"), 2049: ("nfs", "NFS 文件共享"), 2375: ("docker", "Docker API"),
        2376: ("docker-tls", "Docker API (TLS)"), 3000: ("http-dev", "Web 服务 (Grafana / 开发)"),
        3128: ("squid", "HTTP 代理"), 3306: ("mysql", "MySQL"), 3389: ("rdp", "Windows 远程桌面"),
        3689: ("daap", "iTunes 音乐共享"), 4070: ("spotify", "Spotify Connect"), 5000: ("upnp/dsm", "UPnP / AirPlay / Synology DSM"),
        5001: ("dsm-https", "Synology DSM (HTTPS)"), 5037: ("adb-server", "ADB 服务"), 5060: ("sip", "SIP 语音"),
        5222: ("xmpp", "XMPP"), 5353: ("mdns", "mDNS / Bonjour"), 5357: ("wsd", "Windows 网络发现 (WSD)"),
        5432: ("postgresql", "PostgreSQL"), 5555: ("adb", "Android 调试 (ADB)"), 5900: ("vnc", "VNC / 屏幕共享"),
        5985: ("winrm", "Windows 远程管理"), 5986: ("winrm-https", "Windows 远程管理 (HTTPS)"),
        6379: ("redis", "Redis"), 6443: ("kube-api", "Kubernetes API"), 6668: ("tuya", "涂鸦智能设备"),
        7000: ("airplay", "AirPlay"), 7100: ("airplay-fp", "AirPlay 镜像"), 7547: ("tr-069", "运营商远程管理 (TR-069)"),
        8000: ("http-alt", "HTTP 备用 / 海康 SDK"), 8001: ("samsung-tv", "三星电视控制"), 8002: ("samsung-tv-tls", "三星电视控制 (TLS)"),
        8008: ("cast-http", "Google Cast HTTP"), 8009: ("googlecast", "Google Cast"), 8060: ("roku-ecp", "Roku 外部控制"),
        8080: ("http-proxy", "HTTP 备用 / 代理"), 8081: ("http-alt", "HTTP 备用"), 8123: ("home-assistant", "Home Assistant"),
        8291: ("winbox", "MikroTik Winbox"), 8443: ("https-alt", "HTTPS 备用"), 8554: ("rtsp-alt", "RTSP 备用"),
        8883: ("mqtts", "MQTT (TLS)"), 8888: ("http-alt", "HTTP 备用"), 9000: ("http-alt", "Web 服务 (Portainer 等)"),
        9090: ("http-alt", "Web 服务 (Cockpit / Prometheus)"), 9091: ("transmission", "Transmission"),
        9100: ("jetdirect", "RAW 打印 (JetDirect)"), 9443: ("https-alt", "HTTPS 备用"), 10000: ("webmin", "Webmin"),
        27017: ("mongodb", "MongoDB"), 32400: ("plex", "Plex 媒体服务器"), 34567: ("dvr", "XMEye 录像机"),
        37777: ("dahua", "大华设备"), 49152: ("upnp", "UPnP 服务"), 49153: ("upnp", "UPnP 服务"),
        51820: ("wireguard", "WireGuard"), 62078: ("lockdown", "iPhone/iPad 同步服务"),
    ]
}

/// Apple model identifiers (`MacBookPro18,3`) → marketing names, from AppleDB.
public final class AppleModelDatabase: Sendable {
    public static let shared = AppleModelDatabase()

    public struct Model: Sendable, Hashable {
        public let name: String
        public let family: String
    }

    private let models: [String: Model]

    public init(url: URL? = DataFiles.url("apple-models", "tsv")) {
        var map: [String: Model] = [:]
        DataFiles.forEachLine(url) { cols in
            guard cols.count >= 3 else { return }
            map[cols[0].lowercased()] = Model(name: String(cols[1]), family: String(cols[2]))
        }
        models = map
    }

    public func model(for identifier: String) -> Model? {
        models[identifier.trimmingCharacters(in: .whitespaces).lowercased()]
    }
}

/// Port presets for the scanner.
public enum PortPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case common, wellKnown, all, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .common: "常用端口（\(PortPreset.commonPorts.count) 个）"
        case .wellKnown: "知名端口（1–1024）"
        case .all: "全部端口（1–65535）"
        case .custom: "自定义"
        }
    }

    public func ports(custom: String) -> [UInt16] {
        switch self {
        case .common: PortPreset.commonPorts
        case .wellKnown: Array(1...1024)
        case .all: Array(1...65535)
        case .custom: PortScanner.parsePorts(custom)
        }
    }

    /// Hand-picked ports that matter on home and office networks.
    public static let commonPorts: [UInt16] = [
        20, 21, 22, 23, 25, 53, 69, 80, 81, 88, 110, 111, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427, 443,
        445, 465, 500, 515, 548, 554, 587, 623, 631, 636, 873, 902, 990, 993, 995, 1025, 1080, 1194, 1400, 1433,
        1521, 1723, 1755, 1883, 1900, 1935, 2000, 2049, 2082, 2083, 2181, 2375, 2376, 2869, 3000, 3001, 3128,
        3268, 3283, 3306, 3389, 3478, 3689, 3690, 4000, 4070, 4433, 4443, 4567, 4848, 5000, 5001, 5005, 5009,
        5037, 5060, 5061, 5222, 5223, 5228, 5353, 5357, 5432, 5555, 5601, 5672, 5800, 5900, 5901, 5985, 5986,
        6000, 6379, 6443, 6466, 6467, 6668, 7000, 7001, 7080, 7100, 7443, 7547, 7676, 8000, 8001, 8002, 8008,
        8009, 8010, 8060, 8080, 8081, 8082, 8083, 8086, 8088, 8089, 8090, 8096, 8123, 8181, 8200, 8222, 8291,
        8384, 8443, 8444, 8554, 8728, 8800, 8843, 8880, 8883, 8888, 8889, 9000, 9001, 9080, 9090, 9091, 9100,
        9200, 9295, 9443, 9999, 10000, 10001, 10243, 11211, 15672, 17500, 18080, 20000, 27017, 32400, 32469,
        34567, 37777, 49152, 49153, 49154, 50000, 51820, 55443, 62078,
    ]
}
