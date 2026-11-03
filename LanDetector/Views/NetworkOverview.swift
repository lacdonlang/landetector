import LanDetectorKit
import SwiftUI

/// Inspector content when no device is selected: the state of the network at a glance.
/// Every count and row is a shortcut into the list.
struct NetworkOverview: View {
    private let model = AppModel.shared

    var body: some View {
        let counts = model.counts
        let kinds = DeviceKind.allCases.compactMap { kind in counts.kinds[kind].map { (kind, $0) } }
        let largest = kinds.map(\.1).max() ?? 1
        let events = model.recentEvents()
        Form {
            Section {
                header
                HStack(spacing: 0) {
                    StatButton(value: counts.online, title: "在线", color: .green) { model.sidebar = .online }
                    Divider().frame(height: 30)
                    StatButton(value: counts.offline, title: "离线", color: .primary) { model.sidebar = .offline }
                    Divider().frame(height: 30)
                    StatButton(value: counts.recent, title: "新设备", color: .orange) { model.sidebar = .recent }
                }
            }

            if !kinds.isEmpty {
                Section("设备类型") {
                    ForEach(kinds, id: \.0) { kind, count in
                        Button {
                            model.sidebar = .kind(kind)
                        } label: {
                            KindRow(kind: kind, count: count, fraction: Double(count) / Double(largest))
                        }
                        .buttonStyle(.plain)
                        .help("在列表中只显示\(kind.title)")
                    }
                }
            }

            Section("最近动态") {
                if events.isEmpty {
                    Text("还没有上线或离线记录。多扫描几次或开启实时监控后，这里会列出设备的变化。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        if let device = model.device(event.deviceID) {
                            Button {
                                model.selection = [device.id]
                            } label: {
                                EventRow(event: event, device: device)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let iface = model.interface {
                Section("网络信息") {
                    InfoRow(label: "本机 IP", value: iface.ipv4.description, monospaced: true)
                    InfoRow(label: "本机 MAC", value: iface.mac?.description, monospaced: true)
                    InfoRow(label: "网关", value: iface.gateway?.description, monospaced: true)
                    InfoRow(label: "DNS", value: model.dnsServers.joined(separator: "\n").nilIfEmpty, monospaced: true)
                    if let pub = model.publicIP {
                        InfoRow(label: "公网 IPv4", value: pub.ipv4, monospaced: true)
                        InfoRow(label: "公网 IPv6", value: pub.ipv6, monospaced: true)
                        InfoRow(label: "运营商", value: pub.isp)
                        InfoRow(label: "位置", value: [pub.flag, pub.locationText].compactMap { $0 }.joined(separator: " ").nilIfEmpty)
                    }
                }
            }

            Section("扫描") {
                LabeledContent("上次扫描", value: lastScanText)
                LabeledContent("范围", value: rangeText)
                LabeledContent("MAC 来源", value: sourceText)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var header: some View {
        if let iface = model.interface {
            HStack(spacing: 12) {
                Image(systemName: model.shownRemoteSubnet == nil ? iface.kind.symbol : "network")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [.accentColor.opacity(0.8), .accentColor], startPoint: .top,
                                               endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    if let remote = model.shownRemoteSubnet {
                        // A range behind a router: name it after the preset, and say how it is reached.
                        Text(model.selectedRange?.name.nilIfEmpty ?? remote).font(.title3.weight(.semibold))
                        Text(verbatim: "\(remote) · 经由 \(iface.displayName)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(iface.displayName).font(.title3.weight(.semibold))
                        Text(verbatim: NetworkMatcher.subnetKey(iface.ipv4, netmask: iface.netmask))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var lastScanText: String {
        if model.isScanning { return "正在扫描 \(Int(model.progress * 100))%" }
        guard let date = model.lastScanDate else { return "尚未扫描" }
        var text = date.formatted(date: .omitted, time: .shortened)
        if let summary = model.lastScan {
            text += String(format: " · 用时 %.1f 秒 · %d 个地址", summary.duration, summary.hostsProbed)
        }
        return text
    }

    private var rangeText: String {
        if let range = model.selectedRange { return range.name.isEmpty ? range.range : "\(range.name) · \(range.range)" }
        return "整个子网" + (model.interface.map { " · " + NetworkMatcher.subnetKey($0.ipv4, netmask: $0.netmask) } ?? "")
    }

    private var sourceText: String {
        if model.shownRemoteSubnet != nil { return "跨路由，无法获取" }
        return switch model.lastScan?.neighborSource {
        case .sysctl: "系统 ARP 表"
        case .arpCommand: "arp 命令"
        case .unavailable: "不可用（需要 Developer ID 签名）"
        case nil: "—"
        }
    }
}

private struct StatButton: View {
    let value: Int
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(verbatim: "\(value)")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? Color.secondary : color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在列表中显示\(title)的设备")
    }
}

private struct KindRow: View {
    let kind: DeviceKind
    let count: Int
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            DeviceIcon(kind: kind, size: 18)
            Text(kind.title)
            Spacer(minLength: 8)
            Capsule()
                .fill(kind.color.opacity(0.18))
                .frame(width: 72, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(kind.color).frame(width: max(6, 72 * fraction), height: 6)
                }
            Text(verbatim: "\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }
}

private struct EventRow: View {
    let event: DeviceEvent
    let device: Device

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .foregroundStyle(device.hasRealName ? .primary : .secondary)
                    .lineLimit(1)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(event.date.relativeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help("在检查器中查看此设备")
    }

    private var symbol: String {
        switch event.kind {
        case .joined: "plus.circle.fill"
        case .online: "arrow.up.circle.fill"
        case .offline: "arrow.down.circle.fill"
        }
    }

    private var color: Color {
        switch event.kind {
        case .joined: .orange
        case .online: .green
        case .offline: .secondary
        }
    }

    private var label: String {
        switch event.kind {
        case .joined: "首次发现"
        case .online: "上线"
        case .offline: "离线"
        }
    }
}
