import LanDetectorKit
import SwiftUI

enum SettingsTab: String {
    case general, scan, data
}

struct SettingsView: View {
    @AppStorage(Prefs.settingsTab) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("Scanning", systemImage: "dot.radiowaves.left.and.right", value: .scan) { ScanSettings() }
            Tab("Data", systemImage: "externaldrive", value: .data) { DataSettings() }
        }
        .frame(width: 560, height: 470)
    }
}

private struct GeneralSettings: View {
    private let model = AppModel.shared
    @AppStorage(Prefs.autoScan) private var autoScan = true
    @AppStorage(Prefs.showMenuBar) private var showMenuBar = true
    @AppStorage(Prefs.lookupPublicIP) private var lookupPublicIP = true
    @AppStorage(Prefs.notifyNewDevices) private var notify = true
    @AppStorage(Prefs.hideIPv6Only) private var hideIPv6Only = false
    @AppStorage(Prefs.customNameColor) private var highlightCustom = true

    var body: some View {
        Form {
            Section {
                Toggle("Scan automatically at launch", isOn: $autoScan)
                Toggle("Show icon in menu bar", isOn: $showMenuBar)
                Toggle("Notify when live monitoring finds new devices", isOn: $notify)
                    .onChange(of: notify) { _, on in if on { Notifier.requestAuthorization() } }
            }
            Section {
                Toggle("Hide devices with only IPv6 addresses", isOn: $hideIPv6Only)
                Toggle("Show custom names in accent color", isOn: $highlightCustom)
                LabeledContent("List text size") {
                    @Bindable var model = model
                    Slider(value: $model.textScale, in: 0.85...1.4, step: 0.05) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .frame(width: 220)
                }
            }
            Section {
                Toggle("Look up public IP and ISP", isOn: $lookupPublicIP)
                    .onChange(of: lookupPublicIP) { _, _ in model.refreshPublicIP() }
            } footer: {
                Text("Sends requests to ipify.org and ipwho.is. When off, LanDetector doesn’t contact any external service.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScanSettings: View {
    private let model = AppModel.shared
    @AppStorage(Prefs.thoroughness) private var thoroughness = 1.0
    @AppStorage(Prefs.liveInterval) private var liveInterval = 60.0
    @AppStorage(Prefs.useMDNS) private var useMDNS = true
    @AppStorage(Prefs.useNetBIOS) private var useNetBIOS = true
    @AppStorage(Prefs.useDNS) private var useDNS = true
    @AppStorage(Prefs.useSSDP) private var useSSDP = true
    @AppStorage(Prefs.useIPv6) private var useIPv6 = true
    @State private var editing: RangePreset?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Current range", selection: $model.selectedRangeID) {
                    Text("Entire Subnet").tag(UUID?.none)
                    ForEach(model.rangePresets) { preset in
                        Text(preset.title).tag(UUID?.some(preset.id))
                    }
                }
                ForEach(model.rangePresets) { preset in
                    RangePresetRow(preset: preset) {
                        editing = preset
                    } onDelete: {
                        model.rangePresets.removeAll { $0.id == preset.id }
                    }
                }
                Button("Add Range…", systemImage: "plus") { editing = RangePreset(name: "", range: "") }
            } header: {
                Text("Scan Range")
            } footer: {
                Text("You can also switch ranges from the network menu in the toolbar; switching starts a scan right away.")
            }
            Section("Scan Methods") {
                Picker("Thoroughness", selection: $thoroughness) {
                    Text("Fast").tag(0.6)
                    Text("Standard").tag(1.0)
                    Text("Thorough").tag(2.0)
                }
                .pickerStyle(.segmented)
                Toggle("mDNS / Bonjour (host names, services, models)", isOn: $useMDNS)
                Toggle("NetBIOS (Windows / SMB names)", isOn: $useNetBIOS)
                Toggle("Reverse DNS lookup", isOn: $useDNS)
                Toggle("UPnP / SSDP (smart TVs, routers, NAS)", isOn: $useSSDP)
                Toggle("IPv6 neighbor discovery", isOn: $useIPv6)
            }
            Section("Live Monitoring") {
                Picker("Full scan interval", selection: $liveInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                }
                Text("Between full scans, the latency of online devices is refreshed every 10 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { preset in
            RangePresetEditor(preset: preset, isNew: !model.rangePresets.contains { $0.id == preset.id }) { saved in
                if let i = model.rangePresets.firstIndex(where: { $0.id == saved.id }) {
                    model.rangePresets[i] = saved
                } else {
                    model.rangePresets.append(saved)
                    model.selectedRangeID = saved.id
                }
            }
        }
    }
}

/// A saved range with its size and edit / delete buttons.
private struct RangePresetRow: View {
    let preset: RangePreset
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title)
                if let range = preset.ipv4Range {
                    Text((preset.name.isEmpty ? "" : "\(preset.range) · ") + String(localized: "\(range.count) addresses"))
                        .font(.caption)
                        .foregroundStyle(range.count > ScanOptions().maxHosts ? .orange : .secondary)
                } else {
                    Text("Invalid format: \(preset.range)").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button("Edit", systemImage: "pencil", action: onEdit)
                .help("Edit")
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .help("Delete")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

/// Sheet for adding or editing a saved range.
private struct RangePresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var preset: RangePreset
    let isNew: Bool
    let onSave: (RangePreset) -> Void

    var body: some View {
        let range = IPv4Range(string: preset.range)
        let limit = ScanOptions().maxHosts
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $preset.name, prompt: Text("e.g. Office"))
                    TextField("Range", text: $preset.range, prompt: Text("192.168.1.1-254 or 10.0.0.0/22"))
                } footer: {
                    Group {
                        if let range {
                            Text(range.count > limit
                                 ? String(localized: "\(range.description) · \(range.count) addresses; only the \(limit) nearest this Mac are scanned")
                                 : range.description + " · " + String(localized: "\(range.count) addresses"))
                                .foregroundStyle(range.count > limit ? .orange : .secondary)
                        } else if preset.range.isEmpty {
                            Text("A start–end range (192.168.1.10-200, 10.0.0.5-10.0.1.4) or CIDR (10.0.0.0/22).")
                        } else {
                            Text("Invalid format").foregroundStyle(.red)
                        }
                    }
                    // Two lines either way, so the sheet does not jump while typing.
                    .lineLimit(2, reservesSpace: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? String(localized: "Add") : String(localized: "Save")) {
                    preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    preset.range = preset.range.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(preset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(range == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
    }
}

private struct DataSettings: View {
    private let model = AppModel.shared
    @State private var message: String?
    @State private var confirmReset = false
    @State private var updating = false

    var body: some View {
        Form {
            Section("Custom Names") {
                HStack {
                    Button("Export…") { Exporter.exportCustomNames(model.exportCustomNames()) }
                    Button("Import (Keep Existing)…") { importNames(overwrite: false) }
                        .help("On conflict, keep the current names and notes")
                    Button("Import (Overwrite Existing)…") { importNames(overwrite: true) }
                        .help("On conflict, use the names and notes from the imported file")
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("MAC vendors (IEEE)", value: String(localized: "\(OUIDatabase.shared.count) entries"))
                LabeledContent("Port services (IANA)", value: String(localized: "TCP port list"))
                LabeledContent("Apple models (AppleDB)", value: String(localized: "Model identifier map"))
                Button(updating ? String(localized: "Updating…") : String(localized: "Update Vendor Database")) { updateOUI() }
                    .disabled(updating)
            } header: {
                Text("Built-in Databases")
            } footer: {
                Text("Vendor data comes from the public IEEE Registration Authority registries (MA-L / MA-M / MA-S / IAB / CID). Updates take effect after restarting the app.")
            }
            Section {
                Button("Clear All Device History…", role: .destructive) { confirmReset = true }
            } footer: {
                Text("The device database is stored in ~/Library/Application Support/LanDetector.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear device history, custom names and notes for all networks?", isPresented: $confirmReset) {
            Button("Clear", role: .destructive) {
                model.clearResults()
                DeviceStore.deleteAll()
                message = String(localized: "Device history cleared.")
            }
        }
    }

    private func importNames(overwrite: Bool) {
        guard let records = Exporter.pickCustomNamesFile() else { return }
        let n = model.importCustomNames(records, overwrite: overwrite)
        message = String(localized: "Records imported: \(n)")
    }

    private func updateOUI() {
        updating = true
        Task {
            do {
                let count = try await OUIUpdater.update()
                message = String(localized: "Vendor database updated: \(count) entries. Restart the app to use it.")
            } catch {
                message = String(localized: "Update failed: \(error.localizedDescription)")
            }
            updating = false
        }
    }
}
