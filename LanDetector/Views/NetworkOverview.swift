import LanDetectorKit
import SwiftUI

/// Inspector content when no device is selected: the state of the network at a glance.
/// Every count and row is a shortcut into the list.
struct NetworkOverview: View {
    private let model = AppModel.shared

    var body: some View {
        let counts = model.counts
        let kinds = DeviceKind.allCases.compactMap { kind in counts.kinds[kind].map { (kind, $0) } }
        let largest = kinds.map(\.1).max() ?? 1
        let events = model.recentEvents()
        Form {
            Section {
                header
                HStack(spacing: 0) {
                    StatButton(value: counts.online, title: String(localized: "Online"),
                               help: String(localized: "Show online devices in the list"), color: .green) {
                        model.sidebar = .online
                    }
                    Divider().frame(height: 30)
                    StatButton(value: counts.offline, title: String(localized: "Offline"),
                               help: String(localized: "Show offline devices in the list"), color: .primary) {
                        model.sidebar = .offline
                    }
                    Divider().frame(height: 30)
                    StatButton(value: counts.recent, title: String(localized: "New Devices"),
                               help: String(localized: "Show new devices in the list"), color: .orange) {
                        model.sidebar = .recent
                    }
                }
            }

            if !kinds.isEmpty {
                Section("Device Types") {
                    ForEach(kinds, id: \.0) { kind, count in
                        Button {
                            model.sidebar = .kind(kind)
                        } label: {
                            KindRow(kind: kind, count: count, fraction: Double(count) / Double(largest))
                        }
                        .buttonStyle(.plain)
                        .help("Show only \(kind.title) devices in the list")
                    }
                }
            }

            Section("Recent Activity") {
                if events.isEmpty {
                    Text("No devices have come online or gone offline yet. Changes appear here after a few more scans or with live monitoring on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        if let device = model.device(event.deviceID) {
                            Button {
                                model.selection = [device.id]
                            } label: {
                                EventRow(event: event, device: device)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let iface = model.interface {
                Section("Network Info") {
                    InfoRow(label: String(localized: "This Mac’s IP"), value: iface.ipv4.description, monospaced: true)
                    InfoRow(label: String(localized: "This Mac’s MAC"), value: iface.mac?.description, monospaced: true)
                    InfoRow(label: String(localized: "Gateway"), value: iface.gateway?.description, monospaced: true)
                    InfoRow(label: "DNS", value: model.dnsServers.joined(separator: "\n").nilIfEmpty, monospaced: true)
                    if let pub = model.publicIP {
                        InfoRow(label: String(localized: "Public IPv4"), value: pub.ipv4, monospaced: true)
                        InfoRow(label: String(localized: "Public IPv6"), value: pub.ipv6, monospaced: true)
                        InfoRow(label: String(localized: "ISP"), value: pub.isp)
                        InfoRow(label: String(localized: "Location"), value: [pub.flag, pub.locationText].compactMap { $0 }.joined(separator: " ").nilIfEmpty)
                    }
                }
            }

            Section("Scan") {
                LabeledContent("Last Scan", value: lastScanText)
                LabeledContent("Range", value: rangeText)
                LabeledContent("MAC Source", value: sourceText)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var header: some View {
        if let iface = model.interface {
            HStack(spacing: 12) {
                Image(systemName: model.shownRemoteSubnet == nil ? iface.kind.symbol : "network")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [.accentColor.opacity(0.8), .accentColor], startPoint: .top,
                                               endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    if let remote = model.shownRemoteSubnet {
                        // A range behind a router: name it after the preset, and say how it is reached.
                        Text(model.selectedRange?.name.nilIfEmpty ?? remote).font(.title3.weight(.semibold))
                        Text("\(remote) · via \(iface.displayName)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(iface.displayName).font(.title3.weight(.semibold))
                        Text(verbatim: NetworkMatcher.subnetKey(iface.ipv4, netmask: iface.netmask))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var lastScanText: String {
        if model.isScanning { return String(localized: "Scanning \(Int(model.progress * 100))%") }
        guard let date = model.lastScanDate else { return String(localized: "Not scanned yet") }
        var text = date.formatted(date: .omitted, time: .shortened)
        if let summary = model.lastScan {
            let seconds = summary.duration.formatted(.number.precision(.fractionLength(1)))
            text += " · " + String(localized: "\(seconds) s") + " · " + String(localized: "\(summary.hostsProbed) addresses")
        }
        return text
    }

    private var rangeText: String {
        if let range = model.selectedRange { return range.name.isEmpty ? range.range : "\(range.name) · \(range.range)" }
        return String(localized: "Entire Subnet") + (model.interface.map { " · " + NetworkMatcher.subnetKey($0.ipv4, netmask: $0.netmask) } ?? "")
    }

    private var sourceText: String {
        if model.shownRemoteSubnet != nil { return String(localized: "Unavailable across a router") }
        return switch model.lastScan?.neighborSource {
        case .sysctl: String(localized: "System ARP table")
        case .arpCommand: String(localized: "arp command")
        case .unavailable: String(localized: "Unavailable (requires Developer ID signing)")
        case nil: "—"
        }
    }
}

private struct StatButton: View {
    let value: Int
    let title: String
    let help: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(verbatim: "\(value)")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? Color.secondary : color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct KindRow: View {
    let kind: DeviceKind
    let count: Int
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            DeviceIcon(kind: kind, size: 18)
            Text(kind.title)
            Spacer(minLength: 8)
            Capsule()
                .fill(kind.color.opacity(0.18))
                .frame(width: 72, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(kind.color).frame(width: max(6, 72 * fraction), height: 6)
                }
            Text(verbatim: "\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }
}

private struct EventRow: View {
    let event: DeviceEvent
    let device: Device

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .foregroundStyle(device.hasRealName ? .primary : .secondary)
                    .lineLimit(1)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(event.date.relativeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help("Show this device in the inspector")
    }

    private var symbol: String {
        switch event.kind {
        case .joined: "plus.circle.fill"
        case .online: "arrow.up.circle.fill"
        case .offline: "arrow.down.circle.fill"
        }
    }

    private var color: Color {
        switch event.kind {
        case .joined: .orange
        case .online: .green
        case .offline: .secondary
        }
    }

    private var label: String {
        switch event.kind {
        case .joined: String(localized: "Discovered")
        case .online: String(localized: "Came online")
        case .offline: String(localized: "Went offline")
        }
    }
}
