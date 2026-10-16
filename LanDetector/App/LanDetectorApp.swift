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
            AppModel.shared.bootstrap()
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
        CommandGroup(replacing: .newItem) {}

        CommandMenu("扫描") {
            Button(model.isScanning ? "停止扫描" : "开始扫描") {
                model.isScanning ? model.stopScan() : model.startScan()
            }
            .keyboardShortcut("r")
            Button(model.isLive ? "停止实时监控" : "开始实时监控") { model.toggleLive() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("端口扫描…") { model.showPortScanSheet = true }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("清空结果") { model.clearResults() }
                .keyboardShortcut("k")
            Button("刷新公网 IP") { model.refreshPublicIP() }
            Button("刷新网络接口") { model.refreshInterfaces() }
        }

        CommandGroup(before: .toolbar) {
            Button("列表视图") { model.viewMode = .table }
                .keyboardShortcut("1")
            Button("卡片视图") { model.viewMode = .grid }
                .keyboardShortcut("2")
            Button(model.showInspector ? "隐藏检查器" : "显示检查器") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("放大字号") { model.textScale = min(1.4, model.textScale + 0.05) }
                .keyboardShortcut("+")
            Button("缩小字号") { model.textScale = max(0.85, model.textScale - 0.05) }
                .keyboardShortcut("-")
            Button("默认字号") { model.textScale = 1 }
                .keyboardShortcut("0")
            Divider()
        }

        CommandGroup(replacing: .importExport) {
            Menu("导出结果") {
                ForEach(Exporter.Format.allCases) { format in
                    Button(format.title) { Exporter.export(model.visibleDevices, as: format) }
                }
            }
            Button("导出为 CSV…") { Exporter.export(model.visibleDevices, as: .csv) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("导出自定义名称…") { Exporter.exportCustomNames(model.exportCustomNames()) }
            Button("导入自定义名称（软导入）…") {
                if let records = Exporter.pickCustomNamesFile() { _ = model.importCustomNames(records, overwrite: false) }
            }
            Button("导入自定义名称（硬导入）…") {
                if let records = Exporter.pickCustomNamesFile() { _ = model.importCustomNames(records, overwrite: true) }
            }
        }
    }
}
