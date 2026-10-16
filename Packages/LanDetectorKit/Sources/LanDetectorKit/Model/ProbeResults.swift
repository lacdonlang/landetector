import Foundation

/// A Bonjour (DNS-SD) service instance advertised by a device.
public struct BonjourService: Hashable, Codable, Sendable, Identifiable {
    /// Service type without domain, e.g. `_airplay._tcp`.
    public var type: String
    /// Instance name, e.g. "Living Room".
    public var name: String
    public var port: UInt16
    public var txt: [String: String]

    public var id: String { "\(type)|\(name)" }

    public init(type: String, name: String, port: UInt16, txt: [String: String]) {
        self.type = type
        self.name = name
        self.port = port
        self.txt = txt
    }

    /// Human readable description of the service type.
    public var typeDescription: String { BonjourService.knownTypes[type] ?? type }

    public static let knownTypes: [String: String] = [
        "_airplay._tcp": "AirPlay",
        "_raop._tcp": "AirPlay 音频",
        "_companion-link._tcp": "Apple 设备互联",
        "_device-info._tcp": "设备信息",
        "_googlecast._tcp": "Google Cast",
        "_googlezone._tcp": "Google Cast 组",
        "_spotify-connect._tcp": "Spotify Connect",
        "_sonos._tcp": "Sonos",
        "_hap._tcp": "HomeKit 配件",
        "_hap._udp": "HomeKit 配件 (Thread)",
        "_homekit._tcp": "HomeKit",
        "_matter._tcp": "Matter",
        "_matterc._udp": "Matter 配网",
        "_meshcop._udp": "Thread 边界路由器",
        "_printer._tcp": "LPD 打印",
        "_ipp._tcp": "IPP 打印",
        "_ipps._tcp": "IPP 打印 (TLS)",
        "_pdl-datastream._tcp": "RAW 打印",
        "_scanner._tcp": "扫描仪",
        "_uscan._tcp": "AirScan 扫描",
        "_smb._tcp": "SMB 文件共享",
        "_afpovertcp._tcp": "AFP 文件共享",
        "_adisk._tcp": "Time Machine",
        "_nfs._tcp": "NFS",
        "_ftp._tcp": "FTP",
        "_webdav._tcp": "WebDAV",
        "_ssh._tcp": "SSH",
        "_sftp-ssh._tcp": "SFTP",
        "_rfb._tcp": "屏幕共享 (VNC)",
        "_http._tcp": "网页",
        "_https._tcp": "网页 (HTTPS)",
        "_workstation._tcp": "工作站",
        "_sleep-proxy._udp": "睡眠代理",
        "_apple-mobdev2._tcp": "iOS 设备同步",
        "_airport._tcp": "AirPort 基站",
        "_daap._tcp": "iTunes 共享",
        "_touch-able._tcp": "Apple Remote",
        "_amzn-wplay._tcp": "Amazon Fire TV",
        "_androidtvremote2._tcp": "Android TV 遥控",
        "_nvstream._tcp": "NVIDIA GameStream",
        "_plexmediasvr._tcp": "Plex 媒体服务器",
        "_esphomelib._tcp": "ESPHome",
        "_home-assistant._tcp": "Home Assistant",
        "_mqtt._tcp": "MQTT",
        "_hue._tcp": "Philips Hue",
        "_axis-video._tcp": "Axis 摄像头",
        "_rtsp._tcp": "RTSP 视频流",
        "_psia._tcp": "PSIA 摄像头",
        "_shelly._tcp": "Shelly",
        "_elg._tcp": "Elgato",
        "_wled._tcp": "WLED",
        "_nanoleafapi._tcp": "Nanoleaf",
        "_viziocast._tcp": "Vizio",
        "_tidalconnect._tcp": "TIDAL Connect",
        "_beocore._tcp": "Bang & Olufsen",
        "_netaudio-chan._udp": "Dante 音频",
        "_qdiscover._tcp": "QNAP",
        "_ndi._tcp": "NDI 视频",
        "_airdrop._tcp": "AirDrop",
        "_remotepairing._tcp": "远程配对",
        "_mediaremotetv._tcp": "Apple TV 遥控",
        "_trel._udp": "Thread 链路",
        "_srpl-tls._tcp": "Thread SRP",
        "_dns-sd._udp": "DNS-SD",
        "_teamviewer._tcp": "TeamViewer",
        "_miio._udp": "小米 IoT",
        "_xiaomi._tcp": "小米",
        "_eppc._tcp": "远程 Apple 事件",
        "_net-assistant._udp": "Apple Remote Desktop",
        "_ichat._tcp": "信息",
        "_presence._tcp": "信息",
    ]
}

/// What mDNS revealed about one IP address.
public struct MDNSHostInfo: Hashable, Sendable {
    /// `name.local` host name.
    public var hostname: String?
    public var services: [BonjourService]
    /// Additional addresses advertised for the same host.
    public var ipv6: [IPv6Address]
    public var hinfo: String?

    public init(hostname: String? = nil, services: [BonjourService] = [], ipv6: [IPv6Address] = [], hinfo: String? = nil) {
        self.hostname = hostname
        self.services = services
        self.ipv6 = ipv6
        self.hinfo = hinfo
    }
}

/// NetBIOS node status (NBSTAT) result.
public struct NetBIOSInfo: Hashable, Codable, Sendable {
    public var name: String?
    public var group: String?
    public var mac: MACAddress?
    public var names: [String]
}

/// Information from a UPnP device description document.
public struct UPnPInfo: Hashable, Codable, Sendable {
    public var friendlyName: String?
    public var manufacturer: String?
    public var manufacturerURL: String?
    public var modelName: String?
    public var modelNumber: String?
    public var modelDescription: String?
    public var deviceType: String?
    public var serialNumber: String?
    public var presentationURL: String?
    public var server: String?
    public var location: String?

    public init() {}

    /// Short device type, e.g. `MediaRenderer` from `urn:schemas-upnp-org:device:MediaRenderer:1`.
    public var shortDeviceType: String? {
        guard let deviceType else { return nil }
        let parts = deviceType.split(separator: ":")
        return parts.count >= 4 ? String(parts[3]) : deviceType
    }
}

/// Public address information of the current Internet connection.
public struct PublicIPInfo: Hashable, Codable, Sendable {
    public var ipv4: String?
    public var ipv6: String?
    public var isp: String?
    public var country: String?
    public var countryCode: String?
    public var city: String?

    public init() {}

    public var flag: String? {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return nil }
        return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(127397 + $0.value) }))
    }

    public var locationText: String? {
        [city, country].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ").nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
