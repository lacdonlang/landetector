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
            } else if model.interface != nil {
                NetworkOverview()
            } else {
                ContentUnavailableView("没有可用的网络", systemImage: "network.slash")
            }
        }
        // The column keeps its width whatever is selected: content that reported its natural width (long IPv6
        // addresses, host names, TXT records) used to resize the inspector – and with it the list – on every click.
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeviceDetail: View {
    private let model = AppModel.shared
    let device: Device
    @State private var name = ""
    @State private var notes = ""
    @State private var customURL = ""
    @State private var isRenaming = false
    @FocusState private var nameFocused: Bool
    @AppStorage(Prefs.presenceWindow) private var presenceWindow = PresenceWindow.day

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
                if device.manufacturer != device.vendor {
                    InfoRow(label: "制造商", value: device.manufacturer)
                }
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
                    // Recognised service types first; private ones such as `_asquic._udp` go last.
                    ForEach(device.services.sorted { ($0.isKnownType ? 0 : 1, $0.typeDescription) < ($1.isKnownType ? 0 : 1, $1.typeDescription) }) { service in
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

            Section {
                LabeledContent("首次发现", value: device.firstSeen.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("最后在线", value: device.isOnline ? "现在" : device.lastSeen.formatted(date: .abbreviated, time: .shortened))
                if device.presence.isEmpty {
                    Text("完成一次扫描后开始记录在线时间线。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    PresenceTimeline(samples: device.presence, window: presenceWindow)
                }
            } header: {
                HStack {
                    Text("历史")
                    Spacer()
                    if !device.presence.isEmpty {
                        Picker("时间范围", selection: $presenceWindow) {
                            ForEach(PresenceWindow.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
            }

            Section {
                TextField("网址", text: $customURL, prompt: Text(verbatim: device.ipv4.map { "http://\($0)" } ?? "http://"))
                    .onSubmit { model.edit(device.id) { $0.customURL = customURL.nilIfEmpty } }
                ZStack(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("添加备注…")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $notes)
                        .frame(minHeight: 64)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                }
            } header: {
                Text("备注")
            } footer: {
                Text("网址用于“在浏览器中打开”，留空时自动选择设备的网页端口。")
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
            if isRenaming { commitRename() }
        }
        .onChange(of: model.renameRequestID, initial: true) { _, id in
            guard id == device.id else { return }
            model.renameRequestID = nil
            startRenaming()
        }
        .onChange(of: nameFocused) { _, focused in
            if !focused && isRenaming { commitRename() }
        }
        .onChange(of: customURL) { _, value in
            guard value.nilIfEmpty != device.customURL else { return }
            model.edit(device.id) { $0.customURL = value.nilIfEmpty }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            DeviceIcon(kind: device.effectiveKind, size: 52, isOnline: device.isOnline)
            VStack(alignment: .leading, spacing: 4) {
                if isRenaming {
                    TextField("名称", text: $name, prompt: Text(device.displayName))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.weight(.semibold))
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                    Text("留空恢复自动识别的名称 · Esc 取消")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(device.displayName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(device.hasRealName ? .primary : .secondary)
                            .lineLimit(2)
                            .onTapGesture(count: 2, perform: startRenaming)
                        Button(action: startRenaming) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("重命名（也可在列表中按 Return）")
                    }
                    Text([device.model, device.vendor].compactMap { $0 }.uniqued().joined(separator: " · ").nilIfEmpty
                         ?? device.effectiveKind.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if device.isOnline {
                        Chip(text: device.latency.map { "在线 · \(latencyString($0))" } ?? "在线", color: .green,
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
            HStack(spacing: 10) {
                Button {
                    model.toggleWatch([device.id])
                } label: {
                    Image(systemName: device.isWatched ? "bell.fill" : "bell")
                        .font(.title3)
                        .foregroundStyle(device.isWatched ? Color.orange : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(device.isWatched ? "关闭上下线提醒" : "开启上下线提醒：扫描发现它上线或离线时通知你")
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
        }
        .padding(.vertical, 4)
    }

    private func startRenaming() {
        name = device.customName ?? device.displayName
        isRenaming = true
        Task { @MainActor in nameFocused = true }
    }

    private func commitRename() {
        isRenaming = false
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leaving the suggested name untouched must not freeze it as a custom name.
        if device.customName == nil && trimmed == device.displayName { return }
        model.rename(device.id, to: trimmed)
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ActionButton(title: "网页", symbol: "safari", detected: DeviceActions.hasWeb(device)) {
                    DeviceActions.openWeb(device)
                }
                .disabled(device.ipv4 == nil)
                ActionButton(title: "SSH", symbol: "terminal", detected: DeviceActions.hasSSH(device)) {
                    DeviceActions.openSSH(device)
                }
                .disabled(device.ipv4 == nil)
                ActionButton(title: "共享", symbol: "folder", detected: DeviceActions.hasSMB(device)) {
                    DeviceActions.openSMB(device)
                }
                .disabled(device.ipv4 == nil)
                ActionButton(title: "屏幕", symbol: "display", detected: DeviceActions.hasVNC(device)) {
                    DeviceActions.openVNC(device)
                }
                .disabled(device.ipv4 == nil)
                ActionButton(title: "唤醒", symbol: "power") {
                    DeviceActions.wake(device, broadcast: model.interface?.broadcast)
                }
                .disabled(device.mac == nil)
            }
        }
    }
}

/// Every action stays usable (detection can miss a service); a green dot marks services that were seen.
private struct ActionButton: View {
    let title: String
    let symbol: String
    var detected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .overlay(alignment: .topTrailing) {
                if detected {
                    Circle().fill(.green).frame(width: 6, height: 6).offset(x: -4, y: 2)
                }
            }
        }
        .buttonStyle(.glass)
        .help(detected ? "\(title)（已检测到服务）" : title)
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
                    if service.isKnownType {
                        Text(service.typeDescription)
                    } else {
                        Text(verbatim: service.type).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(service.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if service.port != 0 {
                    Text(verbatim: ":\(service.port)")
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
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: String(port))
                .font(.body.monospacedDigit().weight(.medium))
                .frame(width: 54, alignment: .leading)
            // One line for the service (its description already names it), a second only for a banner.
            VStack(alignment: .leading, spacing: 2) {
                Text(service.map { $0.description.isEmpty ? $0.name : $0.description } ?? "未知服务")
                    .lineLimit(1)
                    .help(service.map { "\($0.name)：\($0.description)" } ?? "")
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
                Button("扫描端口…", systemImage: "network.badge.shield.half.filled") { model.showPortScanSheet = true }
                Button("收藏 / 取消收藏", systemImage: "star") { model.toggleFavorite(Set(devices.map(\.id))) }
                Button(devices.allSatisfy(\.isWatched) ? "关闭上下线提醒" : "开启上下线提醒", systemImage: "bell") {
                    model.toggleWatch(Set(devices.map(\.id)))
                }
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
