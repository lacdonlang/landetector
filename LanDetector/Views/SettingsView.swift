import LanDetectorKit
import SwiftUI

enum SettingsTab: String {
    case general, scan, data
}

struct SettingsView: View {
    @AppStorage(Prefs.settingsTab) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("通用", systemImage: "gearshape", value: .general) { GeneralSettings() }
            Tab("扫描", systemImage: "dot.radiowaves.left.and.right", value: .scan) { ScanSettings() }
            Tab("数据", systemImage: "externaldrive", value: .data) { DataSettings() }
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
                Toggle("启动时自动扫描", isOn: $autoScan)
                Toggle("在菜单栏显示图标", isOn: $showMenuBar)
                Toggle("实时监控发现新设备时发送通知", isOn: $notify)
                    .onChange(of: notify) { _, on in if on { Notifier.requestAuthorization() } }
            }
            Section {
                Toggle("隐藏仅有 IPv6 地址的设备", isOn: $hideIPv6Only)
                Toggle("用强调色显示自定义名称", isOn: $highlightCustom)
                LabeledContent("列表字号") {
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
                Toggle("查询公网 IP 与运营商", isOn: $lookupPublicIP)
                    .onChange(of: lookupPublicIP) { _, _ in model.refreshPublicIP() }
            } footer: {
                Text("会向 ipify.org 与 ipwho.is 发送请求。关闭后 LanDetector 不会访问任何外部服务。")
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
                Picker("扫描", selection: $model.selectedRangeID) {
                    Text("整个子网").tag(UUID?.none)
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
                Button("添加范围…", systemImage: "plus") { editing = RangePreset(name: "", range: "") }
            } header: {
                Text("扫描范围")
            } footer: {
                Text("也可以在工具栏的网络菜单中切换范围，切换后立即扫描。")
            }
            Section("扫描方式") {
                Picker("强度", selection: $thoroughness) {
                    Text("快速").tag(0.6)
                    Text("标准").tag(1.0)
                    Text("深入").tag(2.0)
                }
                .pickerStyle(.segmented)
                Toggle("mDNS / Bonjour（主机名、服务、型号）", isOn: $useMDNS)
                Toggle("NetBIOS（Windows / SMB 名称）", isOn: $useNetBIOS)
                Toggle("DNS 反向解析", isOn: $useDNS)
                Toggle("UPnP / SSDP（智能电视、路由器、NAS）", isOn: $useSSDP)
                Toggle("IPv6 邻居发现", isOn: $useIPv6)
            }
            Section("实时监控") {
                Picker("完整扫描间隔", selection: $liveInterval) {
                    Text("30 秒").tag(30.0)
                    Text("1 分钟").tag(60.0)
                    Text("2 分钟").tag(120.0)
                    Text("5 分钟").tag(300.0)
                    Text("10 分钟").tag(600.0)
                }
                Text("两次完整扫描之间，每 10 秒刷新一次在线设备的延迟。")
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
                    Text((preset.name.isEmpty ? "" : "\(preset.range) · ") + "\(range.count) 个地址")
                        .font(.caption)
                        .foregroundStyle(range.count > ScanOptions().maxHosts ? .orange : .secondary)
                } else {
                    Text("格式无效：\(preset.range)").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button("编辑", systemImage: "pencil", action: onEdit)
                .help("编辑")
            Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                .help("删除")
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
                    TextField("名称", text: $preset.name, prompt: Text("例如：办公室"))
                    TextField("范围", text: $preset.range, prompt: Text("192.168.1.1-254 或 10.0.0.0/22"))
                } footer: {
                    Group {
                        if let range {
                            Text("\(range.description) · \(range.count) 个地址"
                                + (range.count > limit ? "，只扫描最靠近本机的 \(limit) 个" : ""))
                                .foregroundStyle(range.count > limit ? .orange : .secondary)
                        } else if preset.range.isEmpty {
                            Text("起止地址（192.168.1.10-200、10.0.0.5-10.0.1.4）或 CIDR（10.0.0.0/22）。")
                        } else {
                            Text("格式无效").foregroundStyle(.red)
                        }
                    }
                    // Two lines either way, so the sheet does not jump while typing.
                    .lineLimit(2, reservesSpace: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "添加" : "存储") {
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
            Section("自定义名称") {
                HStack {
                    Button("导出…") { Exporter.exportCustomNames(model.exportCustomNames()) }
                    Button("软导入…") { importNames(overwrite: false) }
                        .help("冲突时保留当前名称与备注")
                    Button("硬导入…") { importNames(overwrite: true) }
                        .help("冲突时使用导入文件中的名称与备注")
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("MAC 厂商（IEEE）", value: "\(OUIDatabase.shared.count) 条")
                LabeledContent("端口服务（IANA）", value: "TCP 端口库")
                LabeledContent("Apple 型号（AppleDB）", value: "型号标识符映射")
                Button(updating ? "正在更新…" : "在线更新厂商库") { updateOUI() }
                    .disabled(updating)
            } header: {
                Text("内置数据库")
            } footer: {
                Text("厂商数据来自 IEEE Registration Authority 公开注册表（MA-L / MA-M / MA-S / IAB / CID），更新后重启应用生效。")
            }
            Section {
                Button("清除所有设备历史…", role: .destructive) { confirmReset = true }
            } footer: {
                Text("设备库保存在 ~/Library/Application Support/LanDetector。")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清除所有网络的设备历史、自定义名称和备注？", isPresented: $confirmReset) {
            Button("清除", role: .destructive) {
                model.clearResults()
                DeviceStore.deleteAll()
                message = "已清除设备历史。"
            }
        }
    }

    private func importNames(overwrite: Bool) {
        guard let records = Exporter.pickCustomNamesFile() else { return }
        let n = model.importCustomNames(records, overwrite: overwrite)
        message = "已导入 \(n) 条记录。"
    }

    private func updateOUI() {
        updating = true
        Task {
            do {
                let count = try await OUIUpdater.update()
                message = "厂商库已更新：\(count) 条记录，重启后生效。"
            } catch {
                message = "更新失败：\(error.localizedDescription)"
            }
            updating = false
        }
    }
}
