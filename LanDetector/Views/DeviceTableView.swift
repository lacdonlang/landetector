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

    /// `false` when `displayName` is only a guess ("H3C 设备", "网关") rather than a name the device or user gave.
    var hasRealName: Bool {
        customName != nil || friendlyName != nil || mdnsName != nil || netbiosName != nil || dnsName != nil
    }
}

/// A column that the View ▸ 列 menu can show or hide.
struct DeviceColumn: Identifiable {
    let id: String
    let title: String
    let visibleByDefault: Bool

    static let toggleable: [DeviceColumn] = [
        .init(id: "ip", title: "IP 地址", visibleByDefault: true),
        .init(id: "mac", title: "MAC 地址", visibleByDefault: true),
        .init(id: "vendor", title: "厂商", visibleByDefault: true),
        .init(id: "identification", title: "识别", visibleByDefault: true),
        .init(id: "kind", title: "类型", visibleByDefault: false),
        .init(id: "os", title: "系统", visibleByDefault: false),
        .init(id: "hostname", title: "主机名", visibleByDefault: false),
        .init(id: "dns", title: "DNS 名称", visibleByDefault: false),
        .init(id: "mdns", title: "mDNS 名称", visibleByDefault: false),
        .init(id: "smb", title: "SMB 名称", visibleByDefault: false),
        .init(id: "smbGroup", title: "SMB 工作组", visibleByDefault: false),
        .init(id: "ipv6Local", title: "IPv6 本地", visibleByDefault: false),
        .init(id: "ipv6Global", title: "IPv6 全局", visibleByDefault: false),
        .init(id: "ports", title: "开放端口", visibleByDefault: false),
        .init(id: "latency", title: "延迟", visibleByDefault: true),
        .init(id: "lastSeen", title: "最后在线", visibleByDefault: true),
        .init(id: "firstSeen", title: "首次发现", visibleByDefault: false),
        .init(id: "notes", title: "备注", visibleByDefault: false),
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

                TableColumn("名称", value: \Device.sortName) { d in
                    NameCell(device: d)
                }
                .width(min: 150, ideal: 210)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("IP 地址", value: \Device.sortableIP) { d in
                    mono(d.ipv4?.description ?? d.ipv6.first?.description)
                }
                .width(min: 112 * scale, ideal: 118 * scale)
                .customizationID("ip")

                TableColumn("MAC 地址", value: \Device.sortMAC) { d in
                    mono(d.mac?.description)
                }
                .width(min: 126 * scale, ideal: 132 * scale)
                .customizationID("mac")

                TableColumn("厂商", value: \Device.sortVendor) { d in
                    if d.vendor == nil && d.hasPrivateMAC {
                        // Says why there is no vendor, instead of a bare dash.
                        Text("私有地址")
                            .font(.system(size: 12 * scale))
                            .foregroundStyle(.secondary)
                            .help("随机（私有）MAC 地址，不含厂商信息")
                    } else {
                        text(d.vendor).help(d.vendorFull ?? "")
                    }
                }
                .width(min: 60, ideal: 100)
                .customizationID("vendor")

                // LanScan's "Identification": the model when known, otherwise the device type.
                TableColumn("识别", value: \Device.sortIdentification) { d in
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

                TableColumn("类型", value: \Device.sortKind) { d in
                    text(d.effectiveKind.title)
                }
                .width(min: 50, ideal: 70)
                .customizationID("kind")
                .defaultVisibility(.hidden)

                TableColumn("系统", value: \Device.sortOS) { d in text(d.osName) }
                    .width(min: 50, ideal: 80)
                    .customizationID("os")
                    .defaultVisibility(.hidden)
            }
            Group {
                TableColumn("主机名", value: \Device.sortHostname) { d in text(d.hostname) }
                    .width(min: 80, ideal: 150)
                    .customizationID("hostname")
                    .defaultVisibility(.hidden)

                TableColumn("DNS 名称", value: \Device.sortDNS) { d in text(d.dnsName) }
                    .customizationID("dns")
                    .defaultVisibility(.hidden)

                TableColumn("mDNS 名称", value: \Device.sortMDNS) { d in text(d.mdnsName) }
                    .customizationID("mdns")
                    .defaultVisibility(.hidden)

                TableColumn("SMB 名称", value: \Device.sortSMB) { d in text(d.netbiosName) }
                    .customizationID("smb")
                    .defaultVisibility(.hidden)

                TableColumn("SMB 工作组", value: \Device.sortSMBGroup) { d in text(d.netbiosGroup) }
                    .customizationID("smbGroup")
                    .defaultVisibility(.hidden)

                TableColumn("IPv6 本地", value: \Device.sortIPv6Local) { d in
                    mono(d.ipv6LinkLocal.map(\.description).joined(separator: "\n").nilIfEmpty, lines: 3)
                }
                .customizationID("ipv6Local")
                .defaultVisibility(.hidden)

                TableColumn("IPv6 全局", value: \Device.sortIPv6Global) { d in
                    mono(d.ipv6Routable.map(\.description).joined(separator: "\n").nilIfEmpty, lines: 3)
                }
                .customizationID("ipv6Global")
                .defaultVisibility(.hidden)
            }
            Group {
                TableColumn("开放端口", value: \Device.sortPorts) { d in
                    mono(d.openPorts.isEmpty ? nil : d.openPortsText)
                        .help(d.openPorts.map { PortDatabase.shared.label(for: $0) }.joined(separator: "\n"))
                }
                .width(min: 60, ideal: 110)
                .customizationID("ports")
                .defaultVisibility(.hidden)

                TableColumn("延迟", value: \Device.sortLatency) { d in
                    LatencyText(latency: d.isOnline ? d.latency : nil)
                        .font(.system(size: 12 * scale))
                }
                .width(min: 44, ideal: 56)
                .customizationID("latency")

                TableColumn("最后在线", value: \Device.lastSeen) { d in
                    Text(d.isOnline ? "现在" : d.lastSeen.relativeText)
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 64)
                .customizationID("lastSeen")

                TableColumn("首次发现", value: \Device.firstSeen) { d in
                    Text(d.firstSeen.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.secondary)
                }
                .customizationID("firstSeen")
                .defaultVisibility(.hidden)

                TableColumn("备注", value: \Device.notes) { d in text(d.notes.nilIfEmpty) }
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
            if device.isCurrentDevice { Chip(text: "本机", color: .blue) }
            if device.isGateway && device.displayName != "网关" { Chip(text: "网关", color: .indigo) }
            if model.isRecent(device) { Chip(text: "新", color: .orange) }
            if device.isFavorite {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("已收藏")
            }
            if device.isWatched {
                Image(systemName: "bell.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help("已开启上下线提醒")
                    .accessibilityLabel("已开启上下线提醒")
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
            Button("在浏览器中打开", systemImage: "safari") { DeviceActions.openWeb(d) }
                .disabled(d.ipv4 == nil)
            Button("SSH 连接", systemImage: "terminal") { DeviceActions.openSSH(d) }
                .disabled(d.ipv4 == nil)
            Button("连接文件共享 (SMB)", systemImage: "folder") { DeviceActions.openSMB(d) }
                .disabled(d.ipv4 == nil)
            Button("屏幕共享 (VNC)", systemImage: "display") { DeviceActions.openVNC(d) }
                .disabled(d.ipv4 == nil)
            Button("网络唤醒", systemImage: "power") { DeviceActions.wake(d, broadcast: model.interface?.broadcast) }
                .disabled(d.mac == nil)
            Divider()
            Button("重命名…", systemImage: "pencil") { model.requestRename(d.id) }
            Menu("拷贝") {
                if let ip = d.ipv4 { Button("IP 地址") { DeviceActions.copy(ip.description) } }
                if let mac = d.mac { Button("MAC 地址") { DeviceActions.copy(mac.description) } }
                Button("名称") { DeviceActions.copy(d.displayName) }
                if let host = d.hostname { Button("主机名") { DeviceActions.copy(host) } }
                if let vendor = d.vendorFull { Button("厂商") { DeviceActions.copy(vendor) } }
                Divider()
                Button("全部信息") { DeviceActions.copy(Exporter.render([d], as: .markdown)) }
            }
            Menu("设备类型") {
                Button("自动识别（\(d.kind.title)）") { model.edit(d.id) { $0.customKind = nil } }
                Divider()
                ForEach(DeviceKind.allCases) { kind in
                    Button(kind.title) { model.edit(d.id) { $0.customKind = kind } }
                }
            }
        }
        if !devices.isEmpty {
            Button("扫描端口…", systemImage: "network.badge.shield.half.filled") {
                model.selection = ids
                model.showPortScanSheet = true
            }
            Button(devices.allSatisfy(\.isFavorite) ? "取消收藏" : "收藏", systemImage: "star") {
                model.toggleFavorite(ids)
            }
            Button(devices.allSatisfy(\.isWatched) ? "关闭上下线提醒" : "开启上下线提醒", systemImage: "bell") {
                model.toggleWatch(ids)
            }
            Divider()
            Menu("导出所选") {
                ForEach(Exporter.Format.allCases) { format in
                    Button(format.title) { Exporter.export(devices, as: format) }
                }
            }
            Button("从列表中移除", systemImage: "trash", role: .destructive) { model.forget(ids) }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
