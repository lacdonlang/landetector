import LanDetectorKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") { GeneralSettings() }
            Tab("扫描", systemImage: "dot.radiowaves.left.and.right") { ScanSettings() }
            Tab("数据", systemImage: "externaldrive") { DataSettings() }
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
    @AppStorage(Prefs.thoroughness) private var thoroughness = 1.0
    @AppStorage(Prefs.liveInterval) private var liveInterval = 60.0
    @AppStorage(Prefs.useMDNS) private var useMDNS = true
    @AppStorage(Prefs.useNetBIOS) private var useNetBIOS = true
    @AppStorage(Prefs.useDNS) private var useDNS = true
    @AppStorage(Prefs.useSSDP) private var useSSDP = true
    @AppStorage(Prefs.useIPv6) private var useIPv6 = true
    @AppStorage(Prefs.customRangeEnabled) private var customRangeEnabled = false
    @AppStorage(Prefs.customRange) private var customRange = ""

    var body: some View {
        Form {
            Section("扫描范围") {
                Toggle("使用自定义 IP 范围", isOn: $customRangeEnabled)
                if customRangeEnabled {
                    TextField("范围", text: $customRange, prompt: Text("192.168.1.1-254 或 10.0.0.0/22"))
                    if let range = IPv4Range(string: customRange) {
                        Text("\(range.description) · \(range.count) 个地址")
                            .font(.caption)
                            .foregroundStyle(range.count > 4096 ? .orange : .secondary)
                    } else if !customRange.isEmpty {
                        Text("格式无效").font(.caption).foregroundStyle(.red)
                    }
                }
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
