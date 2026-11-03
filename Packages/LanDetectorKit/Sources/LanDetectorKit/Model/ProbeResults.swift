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
    public var typeDescription: String { BonjourService.knownTypes[type].map(localized) ?? type }

    /// English names; `typeDescription` localizes them.
    public static let knownTypes: [String: String] = [
        "_airplay._tcp": "AirPlay",
        "_raop._tcp": "AirPlay audio",
        "_companion-link._tcp": "Apple Continuity",
        "_device-info._tcp": "Device info",
        "_googlecast._tcp": "Google Cast",
        "_googlezone._tcp": "Google Cast group",
        "_spotify-connect._tcp": "Spotify Connect",
        "_sonos._tcp": "Sonos",
        "_hap._tcp": "HomeKit accessory",
        "_hap._udp": "HomeKit accessory (Thread)",
        "_homekit._tcp": "HomeKit",
        "_matter._tcp": "Matter",
        "_matterc._udp": "Matter commissioning",
        "_meshcop._udp": "Thread border router",
        "_printer._tcp": "LPD printing",
        "_ipp._tcp": "IPP printing",
        "_ipps._tcp": "IPP printing (TLS)",
        "_pdl-datastream._tcp": "RAW printing",
        "_scanner._tcp": "Scanner",
        "_uscan._tcp": "AirScan",
        "_smb._tcp": "SMB file sharing",
        "_afpovertcp._tcp": "AFP file sharing",
        "_adisk._tcp": "Time Machine",
        "_nfs._tcp": "NFS",
        "_ftp._tcp": "FTP",
        "_webdav._tcp": "WebDAV",
        "_ssh._tcp": "SSH",
        "_sftp-ssh._tcp": "SFTP",
        "_rfb._tcp": "Screen Sharing (VNC)",
        "_http._tcp": "Web",
        "_https._tcp": "Web (HTTPS)",
        "_workstation._tcp": "Workstation",
        "_sleep-proxy._udp": "Sleep proxy",
        "_apple-mobdev2._tcp": "iOS device sync",
        "_airport._tcp": "AirPort base station",
        "_daap._tcp": "iTunes sharing",
        "_touch-able._tcp": "Apple Remote",
        "_amzn-wplay._tcp": "Amazon Fire TV",
        "_androidtvremote2._tcp": "Android TV remote",
        "_nvstream._tcp": "NVIDIA GameStream",
        "_plexmediasvr._tcp": "Plex Media Server",
        "_esphomelib._tcp": "ESPHome",
        "_home-assistant._tcp": "Home Assistant",
        "_mqtt._tcp": "MQTT",
        "_hue._tcp": "Philips Hue",
        "_axis-video._tcp": "Axis camera",
        "_rtsp._tcp": "RTSP video stream",
        "_psia._tcp": "PSIA camera",
        "_shelly._tcp": "Shelly",
        "_elg._tcp": "Elgato",
        "_wled._tcp": "WLED",
        "_nanoleafapi._tcp": "Nanoleaf",
        "_viziocast._tcp": "Vizio",
        "_tidalconnect._tcp": "TIDAL Connect",
        "_beocore._tcp": "Bang & Olufsen",
        "_netaudio-chan._udp": "Dante audio",
        "_qdiscover._tcp": "QNAP",
        "_ndi._tcp": "NDI video",
        "_airdrop._tcp": "AirDrop",
        "_remotepairing._tcp": "Remote pairing",
        "_mediaremotetv._tcp": "Apple TV remote",
        "_trel._udp": "Thread link",
        "_srpl-tls._tcp": "Thread SRP",
        "_dns-sd._udp": "DNS-SD",
        "_teamviewer._tcp": "TeamViewer",
        "_miio._udp": "Xiaomi IoT",
        "_xiaomi._tcp": "Xiaomi",
        "_eppc._tcp": "Remote Apple Events",
        "_net-assistant._udp": "Apple Remote Desktop",
        "_ichat._tcp": "Messages",
        "_presence._tcp": "Messages",
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
