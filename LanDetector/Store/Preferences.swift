import Foundation
import LanDetectorKit

/// A saved custom IPv4 range (LanScan keeps a list of these next to "whole subnet").
struct RangePreset: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// As typed: `192.168.1.1-254`, `10.0.0.5-10.0.1.4` or `10.0.0.0/22`.
    var range: String

    var ipv4Range: IPv4Range? { IPv4Range(string: range) }
    var title: String { name.isEmpty ? range : name }
}

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
    static let rangePresets = "rangePresets"
    static let selectedRangePreset = "selectedRangePreset"
    static let portPreset = "portPreset"
    static let customPorts = "customPorts"
    static let textScale = "textScale"
    static let viewMode = "viewMode"
    static let selectedInterface = "selectedInterface"
    static let customNameColor = "highlightCustomNames"
    static let presenceWindow = "presenceWindow"
    static let settingsTab = "settingsTab"

    // Earlier versions kept a single custom range; it is migrated into a preset.
    private static let legacyRangeEnabled = "customRangeEnabled"
    private static let legacyRange = "customRange"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoScan: true, showMenuBar: true, lookupPublicIP: true, notifyNewDevices: true, hideIPv6Only: false,
            liveInterval: 60.0, thoroughness: 1.0, useMDNS: true, useNetBIOS: true, useDNS: true, useSSDP: true,
            useIPv6: true, portPreset: PortPreset.common.rawValue, customPorts: "22,80,443,445,3389,5900,8080",
            textScale: 1.0, viewMode: "table", customNameColor: true,
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

    /// Saved custom ranges.
    static var rangePresetsValue: [RangePreset] {
        get {
            migrateLegacyRange()
            return storedRangePresets
        }
        set { storedRangePresets = newValue }
    }

    private static var storedRangePresets: [RangePreset] {
        get { d.data(forKey: rangePresets).flatMap { try? JSONDecoder().decode([RangePreset].self, from: $0) } ?? [] }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: rangePresets) }
    }

    /// The preset scans cover; `nil` scans the whole subnet of the interface.
    static var selectedRangePresetID: UUID? {
        get {
            migrateLegacyRange()
            return d.string(forKey: selectedRangePreset).flatMap(UUID.init(uuidString:))
        }
        set { d.set(newValue?.uuidString, forKey: selectedRangePreset) }
    }

    static func scanOptions() -> ScanOptions {
        var o = ScanOptions()
        o.useMDNS = d.bool(forKey: useMDNS)
        o.useNetBIOS = d.bool(forKey: useNetBIOS)
        o.useDNS = d.bool(forKey: useDNS)
        o.useSSDP = d.bool(forKey: useSSDP)
        o.useIPv6 = d.bool(forKey: useIPv6)
        o.thoroughness = d.double(forKey: thoroughness)
        if let id = selectedRangePresetID, let range = rangePresetsValue.first(where: { $0.id == id })?.ipv4Range {
            o.range = range
        }
        return o
    }

    /// Turns the single custom range of earlier versions into a preset, selected if it was switched on.
    /// Only the app's own domain counts: values passed as launch arguments cannot be removed and would migrate again.
    private static func migrateLegacyRange() {
        guard let domain = Bundle.main.bundleIdentifier.flatMap(d.persistentDomain(forName:)),
              domain[legacyRange] != nil || domain[legacyRangeEnabled] != nil else { return }
        let text = (domain[legacyRange] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let enabled = domain[legacyRangeEnabled] as? Bool ?? false
        d.removeObject(forKey: legacyRange)
        d.removeObject(forKey: legacyRangeEnabled)
        guard !text.isEmpty else { return }
        let preset = RangePreset(name: String(localized: "Custom Range"), range: text)
        storedRangePresets.append(preset)
        if enabled, preset.ipv4Range != nil { selectedRangePresetID = preset.id }
    }
}
