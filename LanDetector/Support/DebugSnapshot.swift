#if DEBUG
import AppKit
import LanDetectorKit
import SwiftUI

/// Debug-only: renders the main window to PNG files without needing screen-recording permission.
///   LANDETECTOR_SNAPSHOT_DIR=/tmp/shots  LanDetector.app/Contents/MacOS/LanDetector
@MainActor
enum DebugSnapshot {
    static func scheduleIfRequested() {
        if ProcessInfo.processInfo.environment["LANDETECTOR_RESIZE_TEST"] != nil { scheduleResizeTest() }
        if let dir = ProcessInfo.processInfo.environment["LANDETECTOR_GALLERY_DIR"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(9))
                await renderGallery(to: URL(fileURLWithPath: dir))
            }
        }
        guard let dir = ProcessInfo.processInfo.environment["LANDETECTOR_SNAPSHOT_DIR"] else { return }
        let base = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let model = AppModel.shared
        let steps: [(Double, String, @MainActor () -> Void)] = [
            (9, "1-table", {
                if let first = model.visibleDevices.first(where: { $0.isCurrentDevice }) ?? model.visibleDevices.first {
                    model.selection = [first.id]
                }
            }),
            (10, "1b-portscan", {
                let ids = model.visibleDevices.filter { $0.isGateway || $0.ipv4?.description.hasSuffix(".1") == true }.map(\.id)
                model.scanPorts(ids, preset: .common, custom: "")
            }),
            (14, "2-gateway", {
                if let gw = model.visibleDevices.first(where: \.isGateway) { model.selection = [gw.id] }
            }),
            (16, "3-grid", { model.viewMode = .grid }),
            (18, "4-dark", { NSApp.appearance = NSAppearance(named: .darkAqua) }),
            (20, "5-dark-table", { model.viewMode = .table }),
        ]
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.0) {
                step.2()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    capture(to: base.appendingPathComponent("\(step.1).png"))
                    if index == steps.count - 1 { NSApp.appearance = nil }
                }
            }
        }
    }

    /// Shrinks and grows the window repeatedly to shake out layout feedback loops.
    static func scheduleResizeTest() {
        let widths: [CGFloat] = [1280, 1000, 860, 760, 700, 1400, 900, 780, 1200, 760, 1600, 820]
        for (i, width) in widths.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(i) * 0.7) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) else { return }
                var frame = window.frame
                // Users cannot drag below the content minimum; setFrame would bypass it.
                let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).width
                frame.size.width = max(width, minimum)
                window.setFrame(frame, display: true, animate: false)
                if ProcessInfo.processInfo.environment["LANDETECTOR_CHAOS"] != nil {
                    let model = AppModel.shared
                    if i % 3 == 1 { model.showInspector.toggle() }
                    if i % 2 == 1 { model.viewMode = model.viewMode == .table ? .grid : .table }
                    if i == 5 { model.sidebar = .online }
                    if i == 7 { model.searchText = "h3c" }
                    if i == 9 { model.searchText = "" }
                }
                FileHandle.standardError.write(Data("resized to \(width) -> \(window.frame.width)\n".utf8))
                if i == widths.count - 1 { FileHandle.standardError.write(Data("RESIZE TEST DONE\n".utf8)) }
            }
        }
        let env = ProcessInfo.processInfo.environment
        if env["LANDETECTOR_GRID"] != nil { AppModel.shared.viewMode = .grid }
        if env["LANDETECTOR_TABLE"] != nil { AppModel.shared.viewMode = .table }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            guard env["LANDETECTOR_NO_SELECTION"] == nil else { return }
            let model = AppModel.shared
            if let d = model.visibleDevices.first(where: { !$0.ipv6.isEmpty }) ?? model.visibleDevices.first { model.selection = [d.id] }
        }
    }

    /// Renders every panel in a plain offscreen window: the glass sidebar / inspector columns of the real
    /// window are composited by the window server and cannot be captured in-process.
    static func renderGallery(to base: URL) async {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let model = AppModel.shared
        let log: (String) -> Void = { FileHandle.standardError.write(Data("gallery: \($0)\n".utf8)) }
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            await renderHosted(SidebarView(), size: CGSize(width: 260, height: 860), dark: dark,
                               to: base.appendingPathComponent("sidebar-\(suffix).png"))
            let picks: [(String, Device?)] = [
                ("self", model.devices.first(where: \.isCurrentDevice)),
                ("gateway", model.devices.first(where: \.isGateway)),
                ("plain", model.devices.first { !$0.isGateway && !$0.isCurrentDevice && $0.isOnline }),
            ]
            for (name, candidate) in picks {
                guard let device = candidate else { continue }
                model.selection = [device.id]
                await renderHosted(DeviceInspector(), size: CGSize(width: 360, height: 1700), dark: dark,
                                   to: base.appendingPathComponent("inspector-\(name)-\(suffix).png"))
            }
        }
        model.selection = Set(model.devices.prefix(3).map(\.id))
        await renderHosted(DeviceInspector(), size: CGSize(width: 360, height: 700), dark: true,
                           to: base.appendingPathComponent("inspector-multi-dark.png"))
        for tab in [SettingsTab.general, .scan, .data] {
            UserDefaults.standard.set(tab.rawValue, forKey: Prefs.settingsTab)
            await renderHosted(SettingsView(), size: CGSize(width: 560, height: 470), dark: true,
                               to: base.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        UserDefaults.standard.set(SettingsTab.general.rawValue, forKey: Prefs.settingsTab)
        if let gw = model.devices.first(where: \.isGateway) { model.selection = [gw.id] }
        await renderHosted(PortScanSheet(), size: CGSize(width: 500, height: 470), dark: true,
                           to: base.appendingPathComponent("portscan-sheet.png"))
        await renderHosted(MenuBarView(), size: CGSize(width: 340, height: 560), dark: true,
                           to: base.appendingPathComponent("menubar.png"))
        if let gw = model.devices.first(where: \.isGateway) {
            model.requestRename(gw.id)
            await renderHosted(DeviceInspector(), size: CGSize(width: 360, height: 420), dark: true,
                               to: base.appendingPathComponent("inspector-rename-dark.png"))
        }
        // The real window, table and grid, at a common laptop width.
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) {
            var frame = window.frame
            frame.size = CGSize(width: 1440, height: 860)
            window.setFrame(frame, display: true)
        }
        if let me = model.devices.first(where: \.isCurrentDevice) { model.selection = [me.id] }
        model.viewMode = .table
        try? await Task.sleep(for: .seconds(1))
        capture(to: base.appendingPathComponent("window-table.png"))
        model.viewMode = .grid
        try? await Task.sleep(for: .seconds(1))
        capture(to: base.appendingPathComponent("window-grid.png"))
        model.viewMode = .table
        log("done")
    }

    private static func renderHosted<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let view = window.contentView?.superview ?? window.contentView,
              let layer = view.layer else { return }
        // Layer rendering also captures list rows (cacheDisplay leaves layer-backed tables blank).
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(window.backgroundColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
