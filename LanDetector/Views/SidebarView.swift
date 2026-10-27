import LanDetectorKit
import SwiftUI

/// Sidebar: which network is shown, and which group of its devices.
struct SidebarView: View {
    private let model = AppModel.shared

    var body: some View {
        @Bindable var model = model
        let counts = model.counts
        List(selection: $model.sidebar) {
            Section {
                NetworkHeader()
                    .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 10, trailing: 4))
                    .selectionDisabled()
            }

            Section("设备") {
                row("全部设备", "square.grid.2x2", counts.all, .all)
                row("在线", "wifi", counts.online, .online)
                row("离线", "moon.zzz", counts.offline, .offline)
                row("新设备", "sparkles", counts.recent, .recent)
                row("收藏", "star", counts.favorites, .favorites)
            }

            let kinds = DeviceKind.allCases.filter { (counts.kinds[$0] ?? 0) > 0 }
            if !kinds.isEmpty {
                Section("类型") {
                    ForEach(kinds) { kind in
                        Label {
                            Text(kind.title)
                        } icon: {
                            DeviceIcon(kind: kind, size: 18)
                        }
                        .badge(counts.kinds[kind] ?? 0)
                        .tag(SidebarItem.kind(kind))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, _ symbol: String, _ count: Int, _ item: SidebarItem) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(item)
    }
}

/// The network being shown: name, subnet and one status line. Clicking it switches interface or scan range;
/// the full network details live in the inspector's overview.
struct NetworkHeader: View {
    private let model = AppModel.shared

    var body: some View {
        if let iface = model.interface {
            Menu {
                NetworkMenuContent()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: iface.kind.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(iface.displayName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(verbatim: model.selectedRange?.range
                                 ?? NetworkMatcher.subnetKey(iface.ipv4, netmask: iface.netmask))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.leading, 2)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("切换网络接口或扫描范围")
        }
    }

    private var statusColor: Color {
        if model.isScanning { return .accentColor }
        return model.isLive ? .green : .secondary.opacity(0.5)
    }

    private var statusText: String {
        let online = model.counts.online
        if model.isScanning { return "正在扫描 \(Int(model.progress * 100))%" }
        if model.isLive { return "实时监控中 · \(online) 台在线" }
        guard let date = model.lastScanDate else { return "尚未扫描" }
        return "\(online) 台在线 · \(date.formatted(date: .omitted, time: .shortened)) 扫描"
    }
}

/// Interfaces, scan ranges and network actions – shown by the sidebar's network header.
struct NetworkMenuContent: View {
    private let model = AppModel.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Section("网络接口") {
            ForEach(model.interfaces) { iface in
                Toggle(isOn: Binding(get: { model.interface?.name == iface.name },
                                     set: { _ in model.selectInterface(iface.name) })) {
                    Label("\(iface.displayName)（\(iface.name)）· \(iface.cidr)", systemImage: iface.kind.symbol)
                }
            }
        }
        Section("扫描范围") {
            Toggle(isOn: rangeBinding(nil)) {
                Text("整个子网" + (model.interface.map { " · " + NetworkMatcher.subnetKey($0.ipv4, netmask: $0.netmask) } ?? ""))
            }
            ForEach(model.rangePresets) { preset in
                Toggle(isOn: rangeBinding(preset.id)) {
                    Text(preset.name.isEmpty ? preset.range : "\(preset.name) · \(preset.range)")
                }
                .disabled(preset.ipv4Range == nil)
            }
            Button("编辑范围…") {
                UserDefaults.standard.set(SettingsTab.scan.rawValue, forKey: Prefs.settingsTab)
                openSettings()
            }
        }
        Divider()
        Button("网络详情") {
            model.selection = []
            model.showInspector = true
        }
        Button("刷新网络接口") { model.refreshInterfaces() }
    }

    /// Checked for the active range; choosing an entry (even the checked one) rescans.
    private func rangeBinding(_ id: UUID?) -> Binding<Bool> {
        Binding(get: { model.selectedRangeID == id }, set: { _ in model.selectRange(id) })
    }
}
