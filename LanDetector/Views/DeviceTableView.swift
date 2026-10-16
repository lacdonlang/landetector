import LanDetectorKit
import SwiftUI

/// Comparable sort keys for table columns.
extension Device {
    var onlineRank: Int { isOnline ? 0 : 1 }
    var sortName: String { displayName }
    var sortMAC: UInt64 { mac?.value ?? .max }
    var sortVendor: String { vendor ?? "\u{FFFF}" }
    var sortKind: Int { effectiveKind.sortOrder }
    var sortModel: String { model ?? "\u{FFFF}" }
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
}

struct DeviceTableView: View {
    private let model = AppModel.shared
    @Environment(\.textScale) private var scale
    @SceneStorage("DeviceTableColumns") private var columns: TableColumnCustomization<Device>
    let devices: [Device]

    var body: some View {
        @Bindable var model = model
        Table(devices, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $columns) {
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
                .width(min: 180, ideal: 230)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("IP 地址", value: \Device.sortableIP) { d in
                    mono(d.ipv4?.description ?? d.ipv6.first?.description)
                }
                .width(min: 105, ideal: 118)
                .customizationID("ip")

                TableColumn("MAC 地址", value: \Device.sortMAC) { d in
                    HStack(spacing: 4) {
                        mono(d.mac?.description)
                        if d.hasPrivateMAC {
                            Image(systemName: "eye.slash")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                                .help("私有（随机）MAC 地址")
                        }
                    }
                }
                .width(min: 135, ideal: 150)
                .customizationID("mac")

                TableColumn("厂商", value: \Device.sortVendor) { d in
                    text(d.vendor).help(d.vendorFull ?? "")
                }
                .width(min: 70, ideal: 110)
                .customizationID("vendor")

                TableColumn("类型", value: \Device.sortKind) { d in
                    Text(d.effectiveKind.title)
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(d.effectiveKind.color)
                }
                .width(min: 50, ideal: 70)
                .customizationID("kind")

                TableColumn("型号", value: \Device.sortModel) { d in text(d.model) }
                    .width(min: 80, ideal: 160)
                    .customizationID("model")
                    .defaultVisibility(.hidden)

                TableColumn("系统", value: \Device.sortOS) { d in text(d.osName) }
                    .width(min: 50, ideal: 70)
                    .customizationID("os")
                    .defaultVisibility(.hidden)
            }
            Group {
                TableColumn("主机名", value: \Device.sortHostname) { d in text(d.hostname) }
                    .width(min: 80, ideal: 150)
                    .customizationID("hostname")

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
                    text(d.openPorts.isEmpty ? nil : d.openPortsText)
                        .help(d.openPorts.map { PortDatabase.shared.label(for: $0) }.joined(separator: "\n"))
                }
                .width(min: 60, ideal: 120)
                .customizationID("ports")

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
                .width(min: 60, ideal: 80)
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
            if ids.count == 1, let d = model.device(ids.first!), d.isOnline, d.ipv4 != nil {
                DeviceActions.openWeb(d)
            } else {
                model.showInspector = true
            }
        }
    }

    private func text(_ value: String?) -> some View {
        Text(value ?? "—")
            .font(.system(size: 12 * scale))
            .foregroundStyle(value == nil ? .tertiary : .primary)
            .lineLimit(2)
    }

    private func mono(_ value: String?, lines: Int = 1) -> some View {
        Text(value ?? "—")
            .font(.system(size: 12 * scale, design: .monospaced))
            .foregroundStyle(value == nil ? .tertiary : .primary)
            .lineLimit(lines)
            .truncationMode(.middle)
    }
}

struct NameCell: View {
    private let model = AppModel.shared
    @Environment(\.textScale) private var scale
    @AppStorage(Prefs.customNameColor) private var highlightCustom = true
    let device: Device

    var body: some View {
        HStack(spacing: 8) {
            DeviceIcon(kind: device.effectiveKind, size: 24 * scale, isOnline: device.isOnline ? nil : false)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(device.displayName)
                        .font(.system(size: 13 * scale, weight: .medium))
                        .foregroundStyle(highlightCustom && device.customName != nil ? Color.accentColor : .primary)
                        .lineLimit(1)
                    if device.isCurrentDevice { Chip(text: "本机", color: .blue) }
                    if device.isGateway && device.displayName != "网关" { Chip(text: "网关", color: .indigo) }
                    if model.sessionNewIDs.contains(device.id) { Chip(text: "新", color: .orange) }
                    if device.isFavorite {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(device.subtitle)
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .opacity(device.isOnline ? 1 : 0.6)
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
            Button("扫描端口…", systemImage: "door.left.hand.open") {
                model.selection = ids
                model.showPortScanSheet = true
            }
            Button(devices.allSatisfy(\.isFavorite) ? "取消收藏" : "收藏", systemImage: "star") {
                model.toggleFavorite(ids)
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
