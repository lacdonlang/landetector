import AppKit
import LanDetectorKit
import SwiftUI

/// Window layout. Each area owns the controls that act on it, placed right above it:
/// sidebar – which network and group; list – scanning, view mode and the search field (it filters the list);
/// inspector – its own toggle.
struct ContentView: View {
    private let model = AppModel.shared
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } detail: {
            DeviceListContainer()
                .navigationTitle(model.listTitle)
                .navigationSubtitle(model.listSummary)
                .toolbar { ListToolbar() }
        }
        // Attached outside the split view, the inspector gets a toolbar section of its own, so nothing of the
        // list's ends up above it.
        .inspector(isPresented: $model.showInspector) {
            DeviceInspector()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                .toolbar {
                    // Inspector toolbar items stay in the toolbar while it is hidden, hence the condition.
                    // Trailing, where 显示检查器 sits while the inspector is closed.
                    if model.showInspector {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                model.showInspector = false
                            } label: {
                                Label("隐藏检查器", systemImage: "sidebar.trailing")
                            }
                            .help("隐藏检查器 (⌥⌘I)")
                        }
                    }
                }
        }
        .sheet(isPresented: $model.showPortScanSheet) {
            PortScanSheet()
        }
        .environment(\.textScale, model.textScale)
    }
}

/// Actions on the device list, shown above it.
struct ListToolbar: ToolbarContent {
    private let model = AppModel.shared

    var body: some ToolbarContent {
        @Bindable var model = model
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
                Label("端口扫描", systemImage: "network.badge.shield.half.filled")
            }
            .help("扫描开放端口 (⌥⌘P)")
            .disabled(model.devices.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("视图", selection: $model.viewMode) {
                Label("列表", systemImage: "list.bullet").tag(ViewMode.table)
                Label("卡片", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("切换列表 / 卡片视图 (⌘1 / ⌘2)")
        }
        // Filters this list; the placeholder names the list it searches.
        ToolbarItem(placement: .primaryAction) {
            ToolbarSearchField(text: $model.searchText, prompt: "搜索" + model.listTitle)
                .frame(width: 190)
        }
        .sharedBackgroundVisibility(.hidden)
        // While the inspector is open its own toolbar carries the toggle, right above it.
        if !model.showInspector {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showInspector = true
                } label: {
                    Label("显示检查器", systemImage: "sidebar.trailing")
                }
                .help("显示检查器 (⌥⌘I)")
            }
        }
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
                if let subnet = model.shownRemoteSubnet {
                    RemoteRangeBanner(subnet: subnet, hasHistory: model.devices.contains { $0.mac != nil })
                } else if showsMACWarning {
                    MACWarningBanner()
                }
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

/// A range behind a router: says what cannot be seen from here, so "未知" does not read as a fault.
private struct RemoteRangeBanner: View {
    let subnet: String
    let hasHistory: Bool

    var body: some View {
        ListBanner(text: message, symbol: "network", style: .secondary, background: .accentColor.opacity(0.08))
    }

    private var message: String {
        let reason = "跨路由扫描 \(subnet)：隔着路由器拿不到 MAC 和 Bonjour 信息"
        return hasHistory ? reason + "，厂商、型号沿用上次直连该网络时的记录，名称向路由器查询。"
                          : reason + "，名称向路由器查询；直连该网络扫描一次即可识别厂商与类型。"
    }
}

private struct MACWarningBanner: View {
    var body: some View {
        ListBanner(text: "读不到 MAC 地址：macOS 27 只向 Developer ID 签名的应用开放 ARP 表，厂商识别和设备合并会受影响。",
                   symbol: "exclamationmark.triangle.fill", style: .orange, background: .orange.opacity(0.12))
    }
}

/// A one-line note above the list.
private struct ListBanner<Style: ShapeStyle>: View {
    let text: String
    let symbol: String
    let style: Style
    let background: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(style)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // Only behind the banner: by default a background would also tint the toolbar above it.
            .background(background, ignoresSafeAreaEdges: [])
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
                    ContentUnavailableView {
                        Label("没有找到“\(model.searchText)”", systemImage: "magnifyingglass")
                    } description: {
                        Text("在“\(model.listTitle)”中没有匹配的设备。")
                    } actions: {
                        if model.sidebar != .all {
                            Button("在全部设备中搜索") { model.sidebar = .all }
                        }
                    }
                } else if model.isScanning {
                    ProgressView("正在发现设备…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("暂无设备", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text(model.devices.isEmpty ? "点击扫描以发现局域网中的设备。" : "“\(model.listTitle)”中没有设备。")
                    } actions: {
                        if model.devices.isEmpty {
                            Button("扫描网络") { model.startScan() }
                                .buttonStyle(.glassProminent)
                                .controlSize(.large)
                        }
                    }
                }
            } else {
                Group {
                    switch model.viewMode {
                    case .table: DeviceTableView(devices: devices)
                    case .grid: DeviceGridView(devices: devices)
                    }
                }
                // Another network's store is a new list, not an edit of this one: replacing every row of a live
                // table that still has a selection makes AppKit report a reentrant delegate. Also starts at the top.
                .id(model.networkKey)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// AppKit's toolbar search field as an ordinary toolbar item, so it can sit with the list's controls:
/// `.searchable` always puts its field at the window's trailing edge, above the inspector.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    private static weak var current: NSSearchField?

    /// Edit ▸ 查找设备 (⌘F).
    static func focus() {
        guard let field = current else { return }
        field.window?.makeFirstResponder(field)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        // Same metrics as the field of NSSearchToolbarItem.
        field.controlSize = .extraLarge
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.drawsBackground = false
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.setAccessibilityLabel("搜索设备")
        Self.current = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt { field.placeholderString = prompt }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor final class Coordinator: NSObject {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func search(_ sender: NSSearchField) { text.wrappedValue = sender.stringValue }
    }
}
