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
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let iface = model.interface else { return "" }
        let range = model.selectedRange.map { " · 范围 \($0.title)" } ?? ""
        return "\(iface.cidr) · 网关 \(iface.gateway?.description ?? "—")\(range)"
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
            Menu {
                ForEach(Exporter.Format.allCases) { format in
                    Button(format.title) { Exporter.export(model.visibleDevices, as: format) }
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .help("导出当前列表")
            .disabled(model.devices.isEmpty)
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

/// Header + table/grid, with empty states.
struct DeviceListContainer: View {
    var body: some View {
        DeviceListContent()
            .safeAreaInset(edge: .top, spacing: 0) {
                ContentHeader()
            }
            // Neither the list nor the header may report an ideal width: the split view sizes the
            // detail column from it, and with the inspector open a narrowing window would otherwise
            // send AppKit into an endless update-constraints loop.
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
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

struct ContentHeader: View {
    private let model = AppModel.shared

    var body: some View {
        let counts = model.counts
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // A horizontal scroll view keeps the header from imposing a minimum width on the split view.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        StatTile(title: "在线设备", value: "\(counts.online)", symbol: "wifi", color: .green)
                        StatTile(title: "已知设备", value: "\(counts.all)", symbol: "square.stack.3d.up", color: .blue)
                        StatTile(title: "新设备", value: "\(counts.recent)", symbol: "sparkles", color: .orange)
                        StatTile(title: scanTitle, value: scanValue,
                                 symbol: model.isLive ? "dot.radiowaves.left.and.right" : "clock",
                                 color: model.isLive ? .green : .purple)
                    }
                    .padding(.vertical, 2)
                }
                .fixedSize(horizontal: false, vertical: true)
                if let ip = model.publicIP?.ipv4 {
                    // Must stay compressible: a fixed minimum width here fights the inspector column
                    // and sends AppKit into an update-constraints loop when the window narrows.
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(model.publicIP?.flag ?? "🌐") \(ip)")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text(model.publicIP?.isp ?? "公网 IP")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, alignment: .trailing)
                    .layoutPriority(-1)
                    .help("公网地址\(model.publicIP?.locationText.map { " · \($0)" } ?? "")")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .animation(.snappy, value: counts.online)

            if model.isScanning {
                HStack(spacing: 8) {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                    Text(model.phase?.rawValue ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
            if showsMACWarning {
                Label("无法读取 MAC 地址：macOS 27 仅向 Developer ID 签名的应用开放 ARP 表，设备合并与厂商识别会受影响。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
        }
        // The header must not report an ideal width: the split view sizes the detail column from it
        // and, with the inspector open, a narrowing window then loops in update-constraints passes.
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
        .background(.bar)
        .animation(.default, value: model.isScanning)
    }

    private var showsMACWarning: Bool {
        guard model.lastScan != nil else { return false }
        let online = model.devices.filter(\.isOnline)
        return online.count > 2 && !online.contains { $0.mac != nil && !$0.isCurrentDevice }
    }

    private var scanTitle: String {
        if model.isScanning { return "扫描中" }
        let time = model.lastScanDate.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return (model.isLive ? "实时监控" : "上次扫描") + time
    }

    private var scanValue: String {
        if model.isScanning { return "\(Int(model.progress * 100))%" }
        guard let d = model.lastScan?.duration else { return "—" }
        return String(format: "%.1f 秒", d)
    }
}

