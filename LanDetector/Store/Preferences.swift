import Foundation
import LanDetectorKit

/// UserDefaults keys and typed accessors. Views bind to the same keys with `@AppStorage`.
enum Prefs {
    static let autoScan = "autoScanOnLaunch"
    static let showMenuBar = "showMenuBarExtra"
    static let lookupPublicIP = "lookupPublicIP"
    static let notifyNewDevices = "notifyNewDevices"
    static let hideIPv6Only = "hideIPv6Only"
    static let liveInterval = "liveInterval"
    static let thoroughness = "scanThoroughness"
    static let useMDNS = "useMDNS"
    static let useNetBIOS = "useNetBIOS"
    static let useDNS = "useDNS"
    static let useSSDP = "useSSDP"
    static let useIPv6 = "useIPv6"
    static let customRangeEnabled = "customRangeEnabled"
    static let customRange = "customRange"
    static let portPreset = "portPreset"
    static let customPorts = "customPorts"
    static let textScale = "textScale"
    static let viewMode = "viewMode"
    static let selectedInterface = "selectedInterface"
    static let customNameColor = "highlightCustomNames"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoScan: true, showMenuBar: true, lookupPublicIP: true, notifyNewDevices: true, hideIPv6Only: false,
            liveInterval: 60.0, thoroughness: 1.0, useMDNS: true, useNetBIOS: true, useDNS: true, useSSDP: true,
            useIPv6: true, customRangeEnabled: false, customRange: "", portPreset: PortPreset.common.rawValue,
            customPorts: "22,80,443,445,3389,5900,8080", textScale: 1.0, viewMode: "table", customNameColor: true,
        ])
    }

    private static var d: UserDefaults { .standard }

    static var autoScanEnabled: Bool { d.bool(forKey: autoScan) }
    static var lookupPublicIPEnabled: Bool { d.bool(forKey: lookupPublicIP) }
    static var notifyEnabled: Bool { d.bool(forKey: notifyNewDevices) }
    static var hideIPv6OnlyEnabled: Bool { d.bool(forKey: hideIPv6Only) }
    static var liveIntervalSeconds: Double { max(15, d.double(forKey: liveInterval)) }

    static var portPresetValue: PortPreset { PortPreset(rawValue: d.string(forKey: portPreset) ?? "") ?? .common }
    static var customPortsValue: String { d.string(forKey: customPorts) ?? "" }

    static func scanOptions() -> ScanOptions {
        var o = ScanOptions()
        o.useMDNS = d.bool(forKey: useMDNS)
        o.useNetBIOS = d.bool(forKey: useNetBIOS)
        o.useDNS = d.bool(forKey: useDNS)
        o.useSSDP = d.bool(forKey: useSSDP)
        o.useIPv6 = d.bool(forKey: useIPv6)
        o.thoroughness = d.double(forKey: thoroughness)
        if d.bool(forKey: customRangeEnabled), let range = IPv4Range(string: d.string(forKey: customRange) ?? "") {
            o.range = range
        }
        return o
    }
}
