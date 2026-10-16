import LanDetectorKit
import SwiftUI

struct DeviceInspector: View {
    private let model = AppModel.shared

    var body: some View {
        let selected = model.selectedDevices
        Group {
            if selected.count == 1, let device = selected.first {
                DeviceDetail(device: device)
                    .id(device.id)
            } else if selected.count > 1 {
                MultiSelectionSummary(devices: selected)
            } else {
                ContentUnavailableView("未选择设备", systemImage: "cursorarrow.click.2",
                                       description: Text("在列表中选择设备以查看详细信息。"))
            }
        }
    }
}

private struct DeviceDetail: View {
    private let model = AppModel.shared
    let device: Device
    @State private var name = ""
    @State private var notes = ""
    @State private var customURL = ""

    var body: some View {
        Form {
            Section {
                header
                actions
            }

            Section("网络") {
                InfoRow(label: "IPv4", value: device.ipv4?.description, monospaced: true)
                InfoRow(label: "MAC", value: device.mac.map { $0.description + (device.hasPrivateMAC ? "（私有）" : "") },
                        monospaced: true)
                InfoRow(label: "厂商", value: device.vendorFull)
                ForEach(device.ipv6LinkLocal, id: \.self) { InfoRow(label: "IPv6 本地", value: $0.description, monospaced: true) }
                ForEach(device.ipv6Routable, id: \.self) { InfoRow(label: "IPv6 全局", value: $0.description, monospaced: true) }
            }

            if device.dnsName != nil || device.mdnsName != nil || device.netbiosName != nil || device.upnp?.friendlyName != nil {
                Section("名称") {
                    InfoRow(label: "DNS", value: device.dnsName)
                    InfoRow(label: "mDNS", value: device.mdnsName)
                    InfoRow(label: "SMB 名称", value: device.netbiosName)
                    InfoRow(label: "SMB 工作组", value: device.netbiosGroup)
                    InfoRow(label: "UPnP 名称", value: device.upnp?.friendlyName)
                }
            }

            Section("识别") {
                Picker("类型", selection: Binding(
                    get: { device.customKind },
                    set: { kind in model.edit(device.id) { $0.customKind = kind } }
                )) {
                    Label("自动（\(device.kind.title)）", systemImage: "wand.and.stars").tag(DeviceKind?.none)
                    Divider()
                    ForEach(DeviceKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(DeviceKind?.some(kind))
                    }
                }
                InfoRow(label: "型号", value: device.model)
                InfoRow(label: "制造商", value: device.manufacturer)
                InfoRow(label: "系统", value: device.osName)
                if let upnp = device.upnp {
                    InfoRow(label: "UPnP 设备", value: [upnp.manufacturer, upnp.modelName, upnp.modelNumber]
                        .compactMap { $0 }.joined(separator: " ").nilIfEmpty)
                    InfoRow(label: "UPnP 类型", value: upnp.shortDeviceType)
                    InfoRow(label: "服务器", value: upnp.server)
                }
            }

            if !device.services.isEmpty {
                Section("Bonjour 服务（\(device.services.count)）") {
                    ForEach(device.services) { service in
                        ServiceRow(service: service)
                    }
                }
            }

            Section {
                if device.openPorts.isEmpty {
                    Text(device.portsScannedAt == nil ? "尚未扫描端口" : "未发现开放端口")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(device.openPorts, id: \.self) { port in
                        PortRow(port: port, device: device)
                    }
                }
            } header: {
                HStack {
                    Text("开放端口")
                    Spacer()
                    if model.portScanRunning {
                        ProgressView(value: model.portScanProgress)
                            .frame(width: 60)
                    } else {
                        Button("扫描") {
                            model.selection = [device.id]
                            model.showPortScanSheet = true
                        }
                        .buttonStyle(.borderless)
                        .disabled(device.ipv4 == nil)
                    }
                }
            } footer: {
                if let date = device.portsScannedAt {
                    Text("扫描于 \(date.formatted(date: .abbreviated, time: .shortened))")
                }
            }

            Section {
                if device.latencyHistory.count >= 2 {
                    LatencyChart(values: device.latencyHistory)
                        .frame(height: 90)
                    let values = device.latencyHistory
                    LabeledContent("平均 / 最小 / 最大") {
                        Text(String(format: "%.1f / %.1f / %.1f ms", values.reduce(0, +) / Double(values.count),
                                    values.min() ?? 0, values.max() ?? 0))
                            .monospacedDigit()
                    }
                } else {
                    LabeledContent("当前延迟") { LatencyText(latency: device.isOnline ? device.latency : nil) }
                }
            } header: {
                HStack {
                    Text("延迟")
                    Spacer()
                    Button(model.pingingID == device.id ? "停止 Ping" : "持续 Ping") {
                        model.togglePing(device.id)
                    }
                    .buttonStyle(.borderless)
                    .disabled(device.ipv4 == nil)
                }
            }

            Section("历史") {
                LabeledContent("首次发现", value: device.firstSeen.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("最后在线", value: device.isOnline ? "现在" : device.lastSeen.formatted(date: .abbreviated, time: .shortened))
            }

            Section("备注") {
                TextField("自定义网址（打开网页时使用）", text: $customURL)
                    .onSubmit { model.edit(device.id) { $0.customURL = customURL.nilIfEmpty } }
                TextEditor(text: $notes)
                    .frame(minHeight: 60)
                    .font(.body)
                    .scrollContentBackground(.hidden)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            name = device.customName ?? ""
            notes = device.notes
            customURL = device.customURL ?? ""
        }
        .task(id: notes) {
            // Debounce typing so the list is not re-sorted on every keystroke.
            guard notes != device.notes else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            model.edit(device.id) { $0.notes = notes }
        }
        .onDisappear {
            if notes != device.notes { model.edit(device.id) { $0.notes = notes } }
            if name != (device.customName ?? "") { model.rename(device.id, to: name) }
        }
        .onChange(of: customURL) { _, value in
            guard value.nilIfEmpty != device.customURL else { return }
            model.edit(device.id) { $0.customURL = value.nilIfEmpty }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            DeviceIcon(kind: device.effectiveKind, size: 56, isOnline: device.isOnline)
            VStack(alignment: .leading, spacing: 4) {
                TextField("名称", text: $name, prompt: Text(device.displayName))
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .onSubmit { model.rename(device.id, to: name) }
                Text([device.model, device.vendor].compactMap { $0 }.uniqued().joined(separator: " · ").nilIfEmpty ?? device.effectiveKind.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if device.isOnline {
                        Chip(text: device.latency.map { String(format: "在线 · %.0f ms", $0) } ?? "在线", color: .green,
                             systemImage: "circle.fill")
                    } else {
                        Chip(text: "离线 · \(device.lastSeen.relativeText)", color: .secondary, systemImage: "moon.zzz.fill")
                    }
                    if device.isCurrentDevice { Chip(text: "本机", color: .blue) }
                    if device.isGateway && device.displayName != "网关" { Chip(text: "网关", color: .indigo) }
                    if device.hasPrivateMAC { Chip(text: "私有地址", color: .purple, systemImage: "eye.slash") }
                }
            }
            Spacer(minLength: 0)
            Button {
                model.toggleFavorite([device.id])
            } label: {
                Image(systemName: device.isFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(device.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(device.isFavorite ? "取消收藏" : "收藏")
        }
        .padding(.vertical, 4)
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ActionButton(title: "网页", symbol: "safari") { DeviceActions.openWeb(device) }
                    .disabled(device.ipv4 == nil)
                ActionButton(title: "SSH", symbol: "terminal") { DeviceActions.openSSH(device) }
                    .disabled(device.ipv4 == nil)
                    .opacity(DeviceActions.hasSSH(device) ? 1 : 0.55)
                ActionButton(title: "共享", symbol: "folder") { DeviceActions.openSMB(device) }
                    .disabled(device.ipv4 == nil)
                    .opacity(DeviceActions.hasSMB(device) ? 1 : 0.55)
                ActionButton(title: "屏幕", symbol: "display") { DeviceActions.openVNC(device) }
                    .disabled(device.ipv4 == nil)
                    .opacity(DeviceActions.hasVNC(device) ? 1 : 0.55)
                ActionButton(title: "唤醒", symbol: "power") {
                    DeviceActions.wake(device, broadcast: model.interface?.broadcast)
                }
                .disabled(device.mac == nil)
            }
        }
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.glass)
        .help(title)
    }
}

private struct ServiceRow: View {
    let service: BonjourService
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if service.txt.isEmpty {
                Text("无 TXT 记录").foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(service.txt.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) {
                        Text(service.txt[key] ?? "")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.typeDescription)
                    Text(service.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if service.port != 0 {
                    Text(":\(service.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PortRow: View {
    let port: UInt16
    let device: Device

    var body: some View {
        let service = PortDatabase.shared.service(for: port)
        HStack {
            Text("\(port)")
                .font(.body.monospacedDigit().weight(.medium))
                .frame(width: 54, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(service?.name ?? "未知服务")
                Text(service?.description ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let banner = device.banners[port] {
                    Text(banner)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tint)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let url = webURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("打开 \(url.absoluteString)")
            }
        }
    }

    private var webURL: URL? {
        guard let ip = device.ipv4 else { return nil }
        switch port {
        case 80: return URL(string: "http://\(ip)")
        case 443: return URL(string: "https://\(ip)")
        case 8443, 5001, 9443, 10443: return URL(string: "https://\(ip):\(port)")
        case 8080, 8000, 8081, 8888, 5000, 3000, 9000, 9090, 8123, 32400, 8008:
            return URL(string: "http://\(ip):\(port)")
        case 22: return URL(string: "ssh://\(ip)")
        case 445: return URL(string: "smb://\(ip)")
        case 5900: return URL(string: "vnc://\(ip)")
        case 21: return URL(string: "ftp://\(ip)")
        default: return nil
        }
    }
}

private struct MultiSelectionSummary: View {
    private let model = AppModel.shared
    let devices: [Device]

    var body: some View {
        Form {
            Section {
                HStack(spacing: -10) {
                    ForEach(devices.prefix(6)) { d in
                        DeviceIcon(kind: d.effectiveKind, size: 40)
                    }
                }
                Text("已选择 \(devices.count) 台设备")
                    .font(.title3.weight(.semibold))
                Text("\(devices.filter(\.isOnline).count) 台在线")
                    .foregroundStyle(.secondary)
            }
            Section("批量操作") {
                Button("扫描端口…", systemImage: "door.left.hand.open") { model.showPortScanSheet = true }
                Button("收藏 / 取消收藏", systemImage: "star") { model.toggleFavorite(Set(devices.map(\.id))) }
                Button("网络唤醒", systemImage: "power") {
                    for d in devices { DeviceActions.wake(d, broadcast: model.interface?.broadcast) }
                }
                Menu("导出所选") {
                    ForEach(Exporter.Format.allCases) { format in
                        Button(format.title) { Exporter.export(devices, as: format) }
                    }
                }
            }
            Section("设备") {
                ForEach(devices) { d in
                    LabeledContent(d.displayName, value: d.ipv4?.description ?? "—")
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
