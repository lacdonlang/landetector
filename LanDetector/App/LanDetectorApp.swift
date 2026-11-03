import LanDetectorKit
import SwiftUI

@main
struct LanDetectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @AppStorage(Prefs.showMenuBar) private var showMenuBar = true

    var body: some Scene {
        Window("LanDetector", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.isLive ? "dot.radiowaves.left.and.right" : "network")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LANDETECTOR_DEMO"] != nil {
                AppModel.shared.showDemo(.make())
                DebugSnapshot.scheduleIfRequested()
                return
            }
            #endif
            AppModel.shared.bootstrap()
            Updater.start()
            #if DEBUG
            DebugSnapshot.scheduleIfRequested()
            #endif
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: Prefs.showMenuBar)
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if Updater.isAvailable {
                Button("Check for Updates…") { Updater.checkForUpdates() }
            }
        }

        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .textEditing) {
            Button("Find Device") { ToolbarSearchField.focus() }
                .keyboardShortcut("f")
        }

        CommandMenu("Scan") {
            Button(model.isScanning ? String(localized: "Stop Scan") : String(localized: "Start Scan")) {
                model.isScanning ? model.stopScan() : model.startScan()
            }
            .keyboardShortcut("r")
            Button(model.isLive ? String(localized: "Stop Live Monitoring") : String(localized: "Start Live Monitoring")) {
                model.toggleLive()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Port Scan…") { model.showPortScanSheet = true }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Clear Results") { model.clearResults() }
                .keyboardShortcut("k")
            Button("Refresh Public IP") { model.refreshPublicIP() }
            Button("Refresh Network Interfaces") { model.refreshInterfaces() }
        }

        CommandMenu("Device") {
            let selected = model.selectedDevices
            let single = selected.count == 1 ? selected.first : nil
            Button("Open in Browser") { if let d = single { DeviceActions.openWeb(d) } }
                .keyboardShortcut("o")
                .disabled(single?.ipv4 == nil)
            Button("Rename…") { if let d = single { model.requestRename(d.id) } }
                .disabled(single == nil)
            Button(selected.allSatisfy(\.isFavorite) && !selected.isEmpty
                   ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
                model.toggleFavorite(model.selection)
            }
            .keyboardShortcut("d")
            .disabled(selected.isEmpty)
            Button(selected.allSatisfy(\.isWatched) && !selected.isEmpty
                   ? String(localized: "Turn Off Online/Offline Alerts") : String(localized: "Turn On Online/Offline Alerts")) {
                model.toggleWatch(model.selection)
            }
            .disabled(selected.isEmpty)
            Divider()
            Button("Copy IP Address") {
                DeviceActions.copy(selected.compactMap { $0.ipv4?.description }.joined(separator: "\n"))
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(selected.allSatisfy { $0.ipv4 == nil })
            Button("Copy MAC Address") {
                DeviceActions.copy(selected.compactMap { $0.mac?.description }.joined(separator: "\n"))
            }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            .disabled(selected.allSatisfy { $0.mac == nil })
            Divider()
            Button("Scan Ports…") { model.showPortScanSheet = true }
                .disabled(selected.isEmpty)
            Button("Wake on LAN") {
                for d in selected { DeviceActions.wake(d, broadcast: model.interface?.broadcast) }
            }
            .disabled(selected.allSatisfy { $0.mac == nil })
            Divider()
            Button("Remove from List") { model.forget(model.selection) }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(selected.isEmpty)
        }

        CommandGroup(before: .toolbar) {
            Button("View as List") { model.viewMode = .table }
                .keyboardShortcut("1")
            Button("View as Cards") { model.viewMode = .grid }
                .keyboardShortcut("2")
            Button(model.showInspector ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")) {
                model.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Menu("Columns") {
                ForEach(DeviceColumn.toggleable) { column in
                    Toggle(column.title, isOn: Binding(
                        get: { model.isColumnVisible(column) },
                        set: { model.setColumn(column, visible: $0) }
                    ))
                }
                Divider()
                Button("Restore Default Columns") { model.resetColumns() }
            }
            Divider()
            Button("Make Text Bigger") { model.textScale = min(1.4, model.textScale + 0.05) }
                .keyboardShortcut("+")
            Button("Make Text Smaller") { model.textScale = max(0.85, model.textScale - 0.05) }
                .keyboardShortcut("-")
            Button("Reset Text Size") { model.textScale = 1 }
                .keyboardShortcut("0")
            Divider()
        }

        CommandGroup(replacing: .importExport) {
            Menu("Export Results") {
                ForEach(Exporter.Format.allCases) { format in
                    Button(format.title) { Exporter.export(model.visibleDevices, as: format) }
                }
            }
            Button("Export as CSV…") { Exporter.export(model.visibleDevices, as: .csv) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Export Custom Names…") { Exporter.exportCustomNames(model.exportCustomNames()) }
            Button("Import Custom Names (Keep Existing)…") {
                if let records = Exporter.pickCustomNamesFile() { _ = model.importCustomNames(records, overwrite: false) }
            }
            Button("Import Custom Names (Overwrite Existing)…") {
                if let records = Exporter.pickCustomNamesFile() { _ = model.importCustomNames(records, overwrite: true) }
            }
        }
    }
}
