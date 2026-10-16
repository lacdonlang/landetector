import LanDetectorKit
import SwiftUI

struct ContentView: View {
    private let model = AppModel.shared
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            DeviceListContainer()
                .inspector(isPresented: $model.showInspector) {
                    DeviceInspector()
                        .inspectorColumnWidth(min: 300, ideal: 350, max: 520)
                }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "搜索名称、IP、MAC、厂商、端口")
        .toolbar { MainToolbar() }
        .sheet(isPresented: $model.showPortScanSheet) {
            PortScanSheet()
        }
        .environment(\.textScale, model.textScale)
        .navigationTitle(model.interface?.displayName ?? "LanDetector")
        // Counts and scan state live here (like Mail's message count) instead of a header that would
        // repeat the sidebar badges and eat vertical space in the list.
        .navigationSubtitle(model.interface == nil ? "" : model.statusSummary)
    }
}

struct MainToolbar: ToolbarContent {
    private let model = AppModel.shared

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) {
            InterfaceMenu()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.isScanning ? model.stopScan() : model.startScan()
            } label: {
                Label(model.isScanning ? "停止" : "扫描", systemImage: model.isScanning ? "stop.fill" : "play.fill")
            }
            .help(model.isScanning ? "停止扫描 (⌘R)" : "扫描网络 (⌘R)")

            Button {
                model.toggleLive()
            } label: {
                Label("实时监控", systemImage: model.isLive ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, isActive: model.isLive)
            }
            .tint(model.isLive ? .green : nil)
            .help(model.isLive ? "停止实时监控 (⇧⌘R)" : "持续监控网络变化 (⇧⌘R)")

            Button {
                model.showPortScanSheet = true
            } label: {
                Label("端口扫描", systemImage: "door.left.hand.open")
            }
            .help("扫描开放端口 (⌥⌘P)")
            .disabled(model.devices.isEmpty)
        }
        ToolbarItem {
            Picker("视图", selection: $model.viewMode) {
                Label("列表", systemImage: "list.bullet").tag(ViewMode.table)
                Label("卡片", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("切换列表 / 卡片视图")
        }
        ToolbarItem {
            Button {
                model.showInspector.toggle()
            } label: {
                Label("检查器", systemImage: "sidebar.trailing")
            }
            .help("显示 / 隐藏检查器 (⌥⌘I)")
        }
    }
}

struct InterfaceMenu: View {
    private let model = AppModel.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            Section("网络接口") {
                ForEach(model.interfaces) { iface in
                    Button {
                        model.selectInterface(iface.name)
                    } label: {
                        Label("\(iface.displayName) (\(iface.name)) · \(iface.cidr)", systemImage: iface.kind.symbol)
                    }
                }
            }
            Section("扫描范围") {
                Toggle(isOn: rangeBinding(nil)) {
                    Text("整个子网" + (model.interface.map { " · \($0.cidr)" } ?? ""))
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
            Button("刷新接口") { model.refreshInterfaces() }
        } label: {
            Label(model.interface?.displayName ?? "无网络", systemImage: model.interface?.kind.symbol ?? "network.slash")
        }
        .help("选择要扫描的网络接口与范围")
    }

    /// Checked for the active range; choosing an entry (even the checked one) rescans.
    private func rangeBinding(_ id: UUID?) -> Binding<Bool> {
        Binding(get: { model.selectedRangeID == id }, set: { _ in model.selectRange(id) })
    }
}

/// Table/grid with a slim scan-progress bar and, only when needed, a warning banner.
struct DeviceListContainer: View {
    private let model = AppModel.shared

    var body: some View {
        DeviceListContent()
            .overlay(alignment: .top) {
                if model.isScanning { ScanProgressBar(progress: model.progress) }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsMACWarning { MACWarningBanner() }
            }
            // Neither the list nor anything above it may report an ideal width: the split view sizes the
            // detail column from it, and with the inspector open a narrowing window would otherwise
            // send AppKit into an endless update-constraints loop.
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .animation(.default, value: model.isScanning)
    }

    /// Several devices answered but none has a MAC: the build cannot read the ARP table.
    private var showsMACWarning: Bool {
        guard model.lastScan != nil else { return false }
        let online = model.devices.filter(\.isOnline)
        return online.count > 2 && !online.contains { $0.mac != nil && !$0.isCurrentDevice }
    }
}

/// A 2-point accent bar along the top edge, like a browser's page-load indicator.
private struct ScanProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.tint)
                .frame(width: max(8, geometry.size.width * progress), height: 2.5)
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement()
        .accessibilityLabel("扫描进度")
        .accessibilityValue("\(Int(progress * 100))%")
    }
}

private struct MACWarningBanner: View {
    var body: some View {
        Label("读不到 MAC 地址：macOS 27 只向 Developer ID 签名的应用开放 ARP 表，厂商识别和设备合并会受影响。",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
    }
}

struct DeviceListContent: View {
    private let model = AppModel.shared

    var body: some View {
        let devices = model.visibleDevices
        Group {
            if model.interface == nil {
                ContentUnavailableView("没有可用的网络", systemImage: "network.slash",
                                       description: Text("请连接 Wi-Fi 或以太网后重试。"))
            } else if devices.isEmpty {
                if !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else if model.isScanning {
                    ProgressView("正在发现设备…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("暂无设备", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text(model.devices.isEmpty ? "点击扫描以发现局域网中的设备。" : "此分组中没有设备。")
                    } actions: {
                        if model.devices.isEmpty {
                            Button("扫描网络") { model.startScan() }
                                .buttonStyle(.glassProminent)
                                .controlSize(.large)
                        }
                    }
                }
            } else {
                switch model.viewMode {
                case .table: DeviceTableView(devices: devices)
                case .grid: DeviceGridView(devices: devices)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
