import AppKit
import LanDetectorKit
import SwiftUI

struct DeviceGridView: View {
    private let model = AppModel.shared
    let devices: [Device]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 14)], spacing: 14) {
                ForEach(devices) { device in
                    DeviceCard(device: device, isSelected: model.selection.contains(device.id))
                        .contentShape(.rect(cornerRadius: 18))
                        .onTapGesture(count: 2) {
                            model.selection = [device.id]
                            model.showInspector = true
                        }
                        .simultaneousGesture(TapGesture().onEnded { select(device.id) })
                        .contextMenu {
                            DeviceContextMenu(ids: model.selection.contains(device.id) ? model.selection : [device.id])
                        }
                }
            }
            .padding(16)
            .animation(.snappy, value: devices.map(\.id))
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func select(_ id: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
        } else if flags.contains(.shift), let last = model.selection.first,
                  let a = devices.firstIndex(where: { $0.id == last }), let b = devices.firstIndex(where: { $0.id == id }) {
            model.selection.formUnion(devices[min(a, b)...max(a, b)].map(\.id))
        } else {
            model.selection = [id]
        }
    }
}

struct DeviceCard: View {
    private let model = AppModel.shared
    let device: Device
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                DeviceIcon(kind: device.effectiveKind, size: 46, isOnline: device.isOnline)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if device.isOnline {
                        LatencyText(latency: device.latency)
                            .font(.caption.weight(.medium))
                    } else {
                        Text(device.lastSeen.relativeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 3) {
                        if model.sessionNewIDs.contains(device.id) { Chip(text: "新", color: .orange) }
                        if device.isFavorite {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(device.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if device.isCurrentDevice { Chip(text: "本机", color: .blue) }
                    if device.isGateway && device.displayName != "网关" { Chip(text: "网关", color: .indigo) }
                }
                Text(device.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(device.ipv4?.description ?? device.ipv6.first?.description ?? "—")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Chip(text: device.effectiveKind.title, color: device.effectiveKind.color)
            }
            if !device.openPorts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(device.openPorts.prefix(8), id: \.self) { port in
                            Chip(text: PortDatabase.shared.service(for: port)?.name.uppercased() ?? "\(port)", color: .secondary)
                                .help(PortDatabase.shared.label(for: port))
                        }
                    }
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [device.effectiveKind.color.opacity(device.isOnline ? 0.14 : 0.05), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .opacity(device.isOnline ? 1 : 0.75)
    }
}
