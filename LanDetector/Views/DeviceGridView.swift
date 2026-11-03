import AppKit
import LanDetectorKit
import SwiftUI

struct DeviceGridView: View {
    private let model = AppModel.shared
    let devices: [Device]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 12)], spacing: 12) {
                ForEach(devices) { device in
                    DeviceCard(device: device, isSelected: model.selection.contains(device.id))
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
        }
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

/// Fixed-size card: every card has the same rows, so the grid stays even whatever a device reports.
/// Content uses a plain fill – Liquid Glass is for controls and navigation, not for content.
struct DeviceCard: View {
    private let model = AppModel.shared
    let device: Device
    let isSelected: Bool
    @State private var hovering = false

    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                DeviceIcon(kind: device.effectiveKind, size: 38, isOnline: device.isOnline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.headline)
                        .foregroundStyle(device.hasRealName ? .primary : .secondary)
                        .lineLimit(1)
                    Text(device.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                badges
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text(device.ipv4?.description ?? device.ipv6.first?.description ?? "—")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if device.isOnline {
                    LatencyText(latency: device.latency)
                        .font(.callout)
                } else {
                    Text("Offline · \(device.lastSeen.relativeText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(height: 96)
        .background(Self.shape.fill(fill))
        .overlay(Self.shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                         lineWidth: isSelected ? 2 : 1))
        .contentShape(Self.shape)
        .opacity(device.isOnline ? 1 : 0.7)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        return Color.primary.opacity(hovering ? 0.07 : 0.04)
    }

    /// Always the same slot, so badges never shift the text.
    private var badges: some View {
        HStack(spacing: 4) {
            if device.isCurrentDevice { Chip(text: String(localized: "This Mac"), color: .blue) }
            if device.isGateway && device.displayName != Device.gatewayFallbackName {
                Chip(text: String(localized: "Gateway"), color: .indigo)
            }
            if model.isRecent(device) { Chip(text: String(localized: "New"), color: .orange) }
            if device.isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small)
            }
            if device.isWatched {
                Image(systemName: "bell.fill").foregroundStyle(.secondary).imageScale(.small)
            }
        }
    }
}
