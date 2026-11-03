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
                    // Trailing, where Show Inspector sits while the inspector is closed.
                    if model.showInspector {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                model.showInspector = false
                            } label: {
                                Label("Hide Inspector", systemImage: "sidebar.trailing")
                            }
                            .help("Hide the inspector (⌥⌘I)")
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
                Label(model.isScanning ? String(localized: "Stop") : String(localized: "Scan"),
                      systemImage: model.isScanning ? "stop.fill" : "play.fill")
            }
            .help(model.isScanning ? String(localized: "Stop scanning (⌘R)") : String(localized: "Scan the network (⌘R)"))

            Button {
                model.toggleLive()
            } label: {
                Label("Live Monitoring", systemImage: model.isLive ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, isActive: model.isLive)
            }
            .tint(model.isLive ? .green : nil)
            .help(model.isLive ? String(localized: "Stop live monitoring (⇧⌘R)")
                               : String(localized: "Monitor the network continuously for changes (⇧⌘R)"))

            Button {
                model.showPortScanSheet = true
            } label: {
                Label("Port Scan", systemImage: "network.badge.shield.half.filled")
            }
            .help("Scan for open ports (⌥⌘P)")
            .disabled(model.devices.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $model.viewMode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.table)
                Label("Cards", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("Switch between list and card views (⌘1 / ⌘2)")
        }
        // Filters this list; the placeholder names the list it searches.
        ToolbarItem(placement: .primaryAction) {
            ToolbarSearchField(text: $model.searchText, prompt: String(localized: "Search \(model.listTitle)"))
                .frame(width: 190)
        }
        .sharedBackgroundVisibility(.hidden)
        // While the inspector is open its own toolbar carries the toggle, right above it.
        if !model.showInspector {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showInspector = true
                } label: {
                    Label("Show Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show the inspector (⌥⌘I)")
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
        .accessibilityLabel("Scan progress")
        .accessibilityValue("\(Int(progress * 100))%")
    }
}

/// A range behind a router: says what cannot be seen from here, so "Unknown" does not read as a fault.
private struct RemoteRangeBanner: View {
    let subnet: String
    let hasHistory: Bool

    var body: some View {
        ListBanner(text: message, symbol: "network", style: .secondary, background: .accentColor.opacity(0.08))
    }

    private var message: String {
        hasHistory
            ? String(localized: "Scanning \(subnet) through a router, which hides MAC addresses and Bonjour. Vendors and models are from the last scan on this network; names come from the router.")
            : String(localized: "Scanning \(subnet) through a router, which hides MAC addresses and Bonjour. Names come from the router; scan once while connected to this network to identify vendors and types.")
    }
}

private struct MACWarningBanner: View {
    var body: some View {
        ListBanner(text: String(localized: "Can’t read MAC addresses: macOS 27 only opens the ARP table to apps signed with a Developer ID. Vendor detection and device merging are affected."),
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
                ContentUnavailableView("No Network Available", systemImage: "network.slash",
                                       description: Text("Connect to Wi-Fi or Ethernet and try again."))
            } else if devices.isEmpty {
                if !model.searchText.isEmpty {
                    ContentUnavailableView {
                        Label("No Results for “\(model.searchText)”", systemImage: "magnifyingglass")
                    } description: {
                        Text("No devices in “\(model.listTitle)” match your search.")
                    } actions: {
                        if model.sidebar != .all {
                            Button("Search All Devices") { model.sidebar = .all }
                        }
                    }
                } else if model.isScanning {
                    ProgressView("Discovering devices…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("No Devices", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text(model.devices.isEmpty ? String(localized: "Click Scan to discover devices on your local network.")
                                                   : String(localized: "There are no devices in “\(model.listTitle)”."))
                    } actions: {
                        if model.devices.isEmpty {
                            Button("Scan Network") { model.startScan() }
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

    /// Edit ▸ Find Device (⌘F).
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
        field.setAccessibilityLabel(String(localized: "Search devices"))
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
