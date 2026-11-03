import LanDetectorKit
import SwiftUI

/// Comparable sort keys and display helpers for table columns.
extension Device {
    var onlineRank: Int { isOnline ? 0 : 1 }
    var sortName: String { displayName }
    var sortMAC: UInt64 { mac?.value ?? .max }
    var sortVendor: String { vendor ?? "\u{FFFF}" }
    var sortKind: Int { effectiveKind.sortOrder }
    var sortHostname: String { hostname ?? "\u{FFFF}" }
    var sortDNS: String { dnsName ?? "\u{FFFF}" }
    var sortMDNS: String { mdnsName ?? "\u{FFFF}" }
    var sortSMB: String { netbiosName ?? "\u{FFFF}" }
    var sortSMBGroup: String { netbiosGroup ?? "\u{FFFF}" }
    var sortIPv6Local: String { ipv6LinkLocal.first?.description ?? "\u{FFFF}" }
    var sortIPv6Global: String { ipv6Routable.first?.description ?? "\u{FFFF}" }
    var sortPorts: Int { openPorts.isEmpty ? Int.max : openPorts.count }
    var sortLatency: Double { isOnline ? (latency ?? 9_999) : 99_999 }
    var sortOS: String { osName ?? "\u{FFFF}" }
    /// Known models first, then devices identified only by type.
    var sortIdentification: String { model.map { "0\($0)" } ?? "1\(effectiveKind.title)" }

    /// `false` when `displayName` is only a guess ("H3C device", "Gateway") rather than a name the device or user gave.
    var hasRealName: Bool {
        customName != nil || friendlyName != nil || mdnsName != nil || netbiosName != nil || dnsName != nil
    }
}

/// A column that the View ▸ Columns menu can show or hide.
struct DeviceColumn: Identifiable {
    let id: String
    let title: String
    let visibleByDefault: Bool

    static let toggleable: [DeviceColumn] = [
        .init(id: "ip", title: String(localized: "IP Address"), visibleByDefault: true),
        .init(id: "mac", title: String(localized: "MAC Address"), visibleByDefault: true),
        .init(id: "vendor", title: String(localized: "Vendor"), visibleByDefault: true),
        .init(id: "identification", title: String(localized: "Identification"), visibleByDefault: true),
        .init(id: "kind", title: String(localized: "Type"), visibleByDefault: false),
        .init(id: "os", title: String(localized: "OS"), visibleByDefault: false),
        .init(id: "hostname", title: String(localized: "Hostname"), visibleByDefault: false),
        .init(id: "dns", title: String(localized: "DNS Name"), visibleByDefault: false),
        .init(id: "mdns", title: String(localized: "mDNS Name"), visibleByDefault: false),
        .init(id: "smb", title: String(localized: "SMB Name"), visibleByDefault: false),
        .init(id: "smbGroup", title: String(localized: "SMB Workgroup"), visibleByDefault: false),
        .init(id: "ipv6Local", title: String(localized: "IPv6 Link-Local"), visibleByDefault: false),
        .init(id: "ipv6Global", title: String(localized: "IPv6 Global"), visibleByDefault: false),
        .init(id: "ports", title: String(localized: "Open Ports"), visibleByDefault: false),
        .init(id: "latency", title: String(localized: "Latency"), visibleByDefault: true),
        .init(id: "lastSeen", title: String(localized: "Last Seen"), visibleByDefault: true),
        .init(id: "firstSeen", title: String(localized: "First Seen"), visibleByDefault: false),
        .init(id: "notes", title: String(localized: "Notes"), visibleByDefault: false),
    ]
}

struct DeviceTableView: View {
    private let model = AppModel.shared
    @Environment(\.textScale) private var scale
    let devices: [Device]

    var body: some View {
        @Bindable var model = model
        Table(devices, selection: $model.selection, sortOrder: $model.sortOrder,
              columnCustomization: $model.columnCustomization) {
            Group {
                TableColumn("", value: \Device.onlineRank) { d in
                    StatusDot(isOnline: d.isOnline)
                }
                .width(12)
                .customizationID("status")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("Name", value: \Device.sortName) { d in
                    NameCell(device: d)
                }
                .width(min: 150, ideal: 210)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("IP Address", value: \Device.sortableIP) { d in
                    mono(d.ipv4?.description ?? d.ipv6.first?.description)
                }
                .width(min: 112 * scale, ideal: 118 * scale)
                .customizationID("ip")

                TableColumn("MAC Address", value: \Device.sortMAC) { d in
                    mono(d.mac?.description)
                }
                .width(min: 126 * scale, ideal: 132 * scale)
                .customizationID("mac")

                TableColumn("Vendor", value: \Device.sortVendor) { d in
                    if d.vendor == nil && d.hasPrivateMAC {
                        // Says why there is no vendor, instead of a bare dash.
                        Text("Private address")
                            .font(.system(size: 12 * scale))
                            .foregroundStyle(.secondary)
                            .help("Randomized (private) MAC address, which carries no vendor information")
                    } else {
                        text(d.vendor).help(d.vendorFull ?? "")
                    }
                }
                .width(min: 60, ideal: 100)
                .customizationID("vendor")

                // LanScan's "Identification": the model when known, otherwise the device type.
                TableColumn("Identification", value: \Device.sortIdentification) { d in
                    if let model = d.model {
                        text(model).help(model)
                    } else {
                        Text(d.effectiveKind.title)
                            .font(.system(size: 12 * scale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .width(min: 80, ideal: 160)
                .customizationID("identification")

                TableColumn("Type", value: \Device.sortKind) { d in
                    text(d.effectiveKind.title)
                }
                .width(min: 50, ideal: 70)
                .customizationID("kind")
                .defaultVisibility(.hidden)

                TableColumn("OS", value: \Device.sortOS) { d in text(d.osName) }
                    .width(min: 50, ideal: 80)
                    .customizationID("os")
                    .defaultVisibility(.hidden)
            }
            Group {
                TableColumn("Hostname", value: \Device.sortHostname) { d in text(d.hostname) }
                    .width(min: 80, ideal: 150)
                    .customizationID("hostname")
                    .defaultVisibility(.hidden)

                TableColumn("DNS Name", value: \Device.sortDNS) { d in text(d.dnsName) }
                    .customizationID("dns")
                    .defaultVisibility(.hidden)

                TableColumn("mDNS Name", value: \Device.sortMDNS) { d in text(d.mdnsName) }
                    .customizationID("mdns")
                    .defaultVisibility(.hidden)

                TableColumn("SMB Name", value: \Device.sortSMB) { d in text(d.netbiosName) }
                    .customizationID("smb")
                    .defaultVisibility(.hidden)

                TableColumn("SMB Workgroup", value: \Device.sortSMBGroup) { d in text(d.netbiosGroup) }
                    .customizationID("smbGroup")
                    .defaultVisibility(.hidden)

                TableColumn("IPv6 Link-Local", value: \Device.sortIPv6Local) { d in
                    mono(d.ipv6LinkLocal.map(\.description).joined(separator: "\n").nilIfEmpty, lines: 3)
                }
                .customizationID("ipv6Local")
                .defaultVisibility(.hidden)

                TableColumn("IPv6 Global", value: \Device.sortIPv6Global) { d in
                    mono(d.ipv6Routable.map(\.description).joined(separator: "\n").nilIfEmpty, lines: 3)
                }
                .customizationID("ipv6Global")
                .defaultVisibility(.hidden)
            }
            Group {
                TableColumn("Open Ports", value: \Device.sortPorts) { d in
                    mono(d.openPorts.isEmpty ? nil : d.openPortsText)
                        .help(d.openPorts.map { PortDatabase.shared.label(for: $0) }.joined(separator: "\n"))
                }
                .width(min: 60, ideal: 110)
                .customizationID("ports")
                .defaultVisibility(.hidden)

                TableColumn("Latency", value: \Device.sortLatency) { d in
                    LatencyText(latency: d.isOnline ? d.latency : nil)
                        .font(.system(size: 12 * scale))
                }
                .width(min: 44, ideal: 56)
                .customizationID("latency")

                TableColumn("Last Seen", value: \Device.lastSeen) { d in
                    Text(d.isOnline ? String(localized: "Now") : d.lastSeen.relativeText)
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 64)
                .customizationID("lastSeen")

                TableColumn("First Seen", value: \Device.firstSeen) { d in
                    Text(d.firstSeen.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.secondary)
                }
                .customizationID("firstSeen")
                .defaultVisibility(.hidden)

                TableColumn("Notes", value: \Device.notes) { d in text(d.notes.nilIfEmpty) }
                    .customizationID("notes")
                    .defaultVisibility(.hidden)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            DeviceContextMenu(ids: ids)
        } primaryAction: { ids in
            // Double-click shows details; opening the device's web page stays an explicit action (⌘O).
            if ids.count == 1 { model.selection = ids }
            model.showInspector = true
        }
        // Finder-style: Return renames the selected device.
        .onKeyPress(.return) {
            guard model.selection.count == 1, let id = model.selection.first else { return .ignored }
            model.requestRename(id)
            return .handled
        }
    }

    private func text(_ value: String?) -> some View {
        Text(value ?? "—")
            .font(.system(size: 12 * scale))
            .foregroundStyle(value == nil ? .tertiary : .primary)
            .lineLimit(1)
    }

    private func mono(_ value: String?, lines: Int = 1) -> some View {
        Text(value ?? "—")
            .font(.system(size: 12 * scale, design: .monospaced))
            .foregroundStyle(value == nil ? .tertiary : .primary)
            .lineLimit(lines)
            .truncationMode(.middle)
    }
}

/// Single-line name cell: type icon, name, badges. Guessed names are dimmed so real ones stand out.
struct NameCell: View {
    private let model = AppModel.shared
    @Environment(\.textScale) private var scale
    @AppStorage(Prefs.customNameColor) private var highlightCustom = true
    let device: Device

    var body: some View {
        HStack(spacing: 7) {
            DeviceIcon(kind: device.effectiveKind, size: 18 * scale, isOnline: device.isOnline ? nil : false)
            Text(device.displayName)
                .font(.system(size: 13 * scale, weight: device.hasRealName ? .medium : .regular))
                .foregroundStyle(nameStyle)
                .lineLimit(1)
                .truncationMode(.tail)
            if device.isCurrentDevice { Chip(text: String(localized: "This Mac"), color: .blue) }
            if device.isGateway && device.displayName != Device.gatewayFallbackName {
                Chip(text: String(localized: "Gateway"), color: .indigo)
            }
            if model.isRecent(device) { Chip(text: String(localized: "New"), color: .orange) }
            if device.isFavorite {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorited")
            }
            if device.isWatched {
                Image(systemName: "bell.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help("Online/offline alerts are on")
                    .accessibilityLabel("Online/offline alerts are on")
            }
        }
        .opacity(device.isOnline ? 1 : 0.6)
        .help(device.subtitle)
    }

    private var nameStyle: AnyShapeStyle {
        if highlightCustom && device.customName != nil { return AnyShapeStyle(Color.accentColor) }
        return device.hasRealName ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }
}

/// Context menu shared by the table and grid views.
struct DeviceContextMenu: View {
    private let model = AppModel.shared
    let ids: Set<String>

    var body: some View {
        let devices = ids.compactMap { model.device($0) }
        if let d = devices.first, devices.count == 1 {
            Button("Open in Browser", systemImage: "safari") { DeviceActions.openWeb(d) }
                .disabled(d.ipv4 == nil)
            Button("Connect via SSH", systemImage: "terminal") { DeviceActions.openSSH(d) }
                .disabled(d.ipv4 == nil)
            Button("Connect to File Sharing (SMB)", systemImage: "folder") { DeviceActions.openSMB(d) }
                .disabled(d.ipv4 == nil)
            Button("Screen Sharing (VNC)", systemImage: "display") { DeviceActions.openVNC(d) }
                .disabled(d.ipv4 == nil)
            Button("Wake on LAN", systemImage: "power") { DeviceActions.wake(d, broadcast: model.interface?.broadcast) }
                .disabled(d.mac == nil)
            Divider()
            Button("Rename…", systemImage: "pencil") { model.requestRename(d.id) }
            Menu("Copy") {
                if let ip = d.ipv4 { Button("IP Address") { DeviceActions.copy(ip.description) } }
                if let mac = d.mac { Button("MAC Address") { DeviceActions.copy(mac.description) } }
                Button("Name") { DeviceActions.copy(d.displayName) }
                if let host = d.hostname { Button("Hostname") { DeviceActions.copy(host) } }
                if let vendor = d.vendorFull { Button("Vendor") { DeviceActions.copy(vendor) } }
                Divider()
                Button("All Details") { DeviceActions.copy(Exporter.render([d], as: .markdown)) }
            }
            Menu("Device Type") {
                Button("Automatic (\(d.kind.title))") { model.edit(d.id) { $0.customKind = nil } }
                Divider()
                ForEach(DeviceKind.allCases) { kind in
                    Button(kind.title) { model.edit(d.id) { $0.customKind = kind } }
                }
            }
        }
        if !devices.isEmpty {
            Button("Scan Ports…", systemImage: "network.badge.shield.half.filled") {
                model.selection = ids
                model.showPortScanSheet = true
            }
            Button(devices.allSatisfy(\.isFavorite) ? String(localized: "Unfavorite") : String(localized: "Favorite"),
                   systemImage: "star") {
                model.toggleFavorite(ids)
            }
            Button(devices.allSatisfy(\.isWatched) ? String(localized: "Turn Off Online/Offline Alerts")
                                                   : String(localized: "Turn On Online/Offline Alerts"),
                   systemImage: "bell") {
                model.toggleWatch(ids)
            }
            Divider()
            Menu("Export Selection") {
                ForEach(Exporter.Format.allCases) { format in
                    Button(format.title) { Exporter.export(devices, as: format) }
                }
            }
            Button("Remove from List", systemImage: "trash", role: .destructive) { model.forget(ids) }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
