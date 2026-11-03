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
                ContentUnavailableView("No Network Available", systemImage: "network.slash")
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

            Section("Network") {
                InfoRow(label: "IPv4", value: device.ipv4?.description, monospaced: true)
                InfoRow(label: "MAC", value: device.mac.map { device.hasPrivateMAC ? String(localized: "\($0.description) (private)") : $0.description },
                        monospaced: true)
                InfoRow(label: String(localized: "Vendor"), value: device.vendorFull)
                ForEach(device.ipv6LinkLocal, id: \.self) { InfoRow(label: String(localized: "IPv6 link-local"), value: $0.description, monospaced: true) }
                ForEach(device.ipv6Routable, id: \.self) { InfoRow(label: String(localized: "IPv6 global"), value: $0.description, monospaced: true) }
            }

            if device.dnsName != nil || device.mdnsName != nil || device.netbiosName != nil || device.upnp?.friendlyName != nil {
                Section("Names") {
                    InfoRow(label: "DNS", value: device.dnsName)
                    InfoRow(label: "mDNS", value: device.mdnsName)
                    InfoRow(label: String(localized: "SMB name"), value: device.netbiosName)
                    InfoRow(label: String(localized: "SMB workgroup"), value: device.netbiosGroup)
                    InfoRow(label: String(localized: "UPnP name"), value: device.upnp?.friendlyName)
                }
            }

            Section("Identification") {
                Picker("Type", selection: Binding(
                    get: { device.customKind },
                    set: { kind in model.edit(device.id) { $0.customKind = kind } }
                )) {
                    Label("Automatic (\(device.kind.title))", systemImage: "wand.and.stars").tag(DeviceKind?.none)
                    Divider()
                    ForEach(DeviceKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(DeviceKind?.some(kind))
                    }
                }
                InfoRow(label: String(localized: "Model"), value: device.model)
                if device.manufacturer != device.vendor {
                    InfoRow(label: String(localized: "Manufacturer"), value: device.manufacturer)
                }
                InfoRow(label: String(localized: "OS"), value: device.osName)
                if let upnp = device.upnp {
                    InfoRow(label: String(localized: "UPnP device"), value: [upnp.manufacturer, upnp.modelName, upnp.modelNumber]
                        .compactMap { $0 }.joined(separator: " ").nilIfEmpty)
                    InfoRow(label: String(localized: "UPnP type"), value: upnp.shortDeviceType)
                    InfoRow(label: String(localized: "Server"), value: upnp.server)
                }
            }

            if !device.services.isEmpty {
                Section("Bonjour Services (\(device.services.count))") {
                    // Recognised service types first; private ones such as `_asquic._udp` go last.
                    ForEach(device.services.sorted { ($0.isKnownType ? 0 : 1, $0.typeDescription) < ($1.isKnownType ? 0 : 1, $1.typeDescription) }) { service in
                        ServiceRow(service: service)
                    }
                }
            }

            Section {
                if device.openPorts.isEmpty {
                    Text(device.portsScannedAt == nil ? String(localized: "Ports not scanned yet") : String(localized: "No open ports found"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(device.openPorts, id: \.self) { port in
                        PortRow(port: port, device: device)
                    }
                }
            } header: {
                HStack {
                    Text("Open Ports")
                    Spacer()
                    if model.portScanRunning {
                        ProgressView(value: model.portScanProgress)
                            .frame(width: 60)
                    } else {
                        Button("Scan") {
                            model.selection = [device.id]
                            model.showPortScanSheet = true
                        }
                        .buttonStyle(.borderless)
                        .disabled(device.ipv4 == nil)
                    }
                }
            } footer: {
                if let date = device.portsScannedAt {
                    Text("Scanned \(date.formatted(date: .abbreviated, time: .shortened))")
                }
            }

            Section {
                if device.latencyHistory.count >= 2 {
                    LatencyChart(values: device.latencyHistory)
                        .frame(height: 90)
                    let values = device.latencyHistory
                    LabeledContent("Avg / Min / Max") {
                        Text(String(format: "%.1f / %.1f / %.1f ms", values.reduce(0, +) / Double(values.count),
                                    values.min() ?? 0, values.max() ?? 0))
                            .monospacedDigit()
                    }
                } else {
                    LabeledContent("Current latency") { LatencyText(latency: device.isOnline ? device.latency : nil) }
                }
            } header: {
                HStack {
                    Text("Latency")
                    Spacer()
                    Button(model.pingingID == device.id ? String(localized: "Stop Ping") : String(localized: "Ping Continuously")) {
                        model.togglePing(device.id)
                    }
                    .buttonStyle(.borderless)
                    .disabled(device.ipv4 == nil)
                }
            }

            Section {
                LabeledContent("First seen", value: device.firstSeen.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Last seen", value: device.isOnline ? String(localized: "Now") : device.lastSeen.formatted(date: .abbreviated, time: .shortened))
                if device.presence.isEmpty {
                    Text("The presence timeline starts after a scan completes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    PresenceTimeline(samples: device.presence, window: presenceWindow)
                }
            } header: {
                HStack {
                    Text("History")
                    Spacer()
                    if !device.presence.isEmpty {
                        Picker("Time range", selection: $presenceWindow) {
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
                TextField("URL", text: $customURL, prompt: Text(verbatim: device.ipv4.map { "http://\($0)" } ?? "http://"))
                    .onSubmit { model.edit(device.id) { $0.customURL = customURL.nilIfEmpty } }
                ZStack(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Add notes…")
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
                Text("Notes")
            } footer: {
                Text("The URL is used by “Open in Browser”. Leave it empty to pick the device’s web port automatically.")
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
                    TextField("Name", text: $name, prompt: Text(device.displayName))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.weight(.semibold))
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                    Text("Leave empty to restore the detected name · Esc to cancel")
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
                        .help("Rename (or press Return in the list)")
                    }
                    Text([device.model, device.vendor].compactMap { $0 }.uniqued().joined(separator: " · ").nilIfEmpty
                         ?? device.effectiveKind.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if device.isOnline {
                        Chip(text: device.latency.map { String(localized: "Online · \(latencyString($0))") } ?? String(localized: "Online"),
                             color: .green, systemImage: "circle.fill")
                    } else {
                        Chip(text: String(localized: "Offline · \(device.lastSeen.relativeText)"), color: .secondary, systemImage: "moon.zzz.fill")
                    }
                    if device.isCurrentDevice { Chip(text: String(localized: "This Mac"), color: .blue) }
                    if device.isGateway && device.displayName != Device.gatewayFallbackName {
                        Chip(text: String(localized: "Gateway"), color: .indigo)
                    }
                    if device.hasPrivateMAC { Chip(text: String(localized: "Private address"), color: .purple, systemImage: "eye.slash") }
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
                .help(device.isWatched ? String(localized: "Turn off online/offline alerts")
                      : String(localized: "Turn on online/offline alerts: get notified when a scan sees this device come online or go offline"))
                Button {
                    model.toggleFavorite([device.id])
                } label: {
                    Image(systemName: device.isFavorite ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(device.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(device.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))
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
                ActionButton(title: String(localized: "Web"), symbol: "safari", detected: DeviceActions.hasWeb(device)) {
                    DeviceActions.openWeb(device)
                }
                .disabled(device.ipv4 == nil)
                ActionButton(title: "SSH", symbol: "terminal", detected: DeviceActions.hasSSH(device)) {
                    DeviceActions.openSSH(device)
                }
                .disabled(device.ipv4 == nil)
                ActionButton(title: String(localized: "Files"), symbol: "folder", detected: DeviceActions.hasSMB(device)) {
                    DeviceActions.openSMB(device)
                }
                .disabled(device.ipv4 == nil)
                ActionButton(title: String(localized: "Screen"), symbol: "display", detected: DeviceActions.hasVNC(device)) {
                    DeviceActions.openVNC(device)
                }
                .disabled(device.ipv4 == nil)
                ActionButton(title: String(localized: "Wake"), symbol: "power") {
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
        .help(detected ? String(localized: "\(title) (service detected)") : title)
    }
}

private struct ServiceRow: View {
    let service: BonjourService
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if service.txt.isEmpty {
                Text("No TXT records").foregroundStyle(.secondary).font(.caption)
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
                Text(service.map { $0.description.isEmpty ? $0.name : $0.description } ?? String(localized: "Unknown service"))
                    .lineLimit(1)
                    .help(service.map { String(localized: "\($0.name): \($0.description)") } ?? "")
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
                .help("Open \(url.absoluteString)")
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
                Text("\(devices.count) devices selected")
                    .font(.title3.weight(.semibold))
                Text("\(devices.filter(\.isOnline).count) online")
                    .foregroundStyle(.secondary)
            }
            Section("Actions") {
                Button("Scan Ports…", systemImage: "network.badge.shield.half.filled") { model.showPortScanSheet = true }
                Button("Add to / Remove from Favorites", systemImage: "star") { model.toggleFavorite(Set(devices.map(\.id))) }
                Button(devices.allSatisfy(\.isWatched) ? String(localized: "Turn Off Online/Offline Alerts")
                                                       : String(localized: "Turn On Online/Offline Alerts"), systemImage: "bell") {
                    model.toggleWatch(Set(devices.map(\.id)))
                }
                Button("Wake on LAN", systemImage: "power") {
                    for d in devices { DeviceActions.wake(d, broadcast: model.interface?.broadcast) }
                }
                Menu("Export Selected") {
                    ForEach(Exporter.Format.allCases) { format in
                        Button(format.title) { Exporter.export(devices, as: format) }
                    }
                }
            }
            Section("Devices") {
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
