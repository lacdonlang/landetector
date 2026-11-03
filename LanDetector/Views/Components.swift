import Charts
import LanDetectorKit
import SwiftUI

extension DeviceKind {
    var color: Color {
        switch self {
        case .router: Color(red: 0.16, green: 0.47, blue: 1.0)
        case .networkDevice: Color(red: 0.0, green: 0.62, blue: 0.75)
        case .computer, .laptop: Color(red: 0.36, green: 0.36, blue: 0.95)
        case .server: Color(red: 0.42, green: 0.48, blue: 0.58)
        case .nas: Color(red: 0.62, green: 0.45, blue: 0.30)
        case .phone: Color(red: 0.13, green: 0.72, blue: 0.42)
        case .tablet: Color(red: 0.0, green: 0.70, blue: 0.62)
        case .watch: Color(red: 0.95, green: 0.33, blue: 0.55)
        case .tv, .mediaPlayer: Color(red: 0.62, green: 0.32, blue: 0.95)
        case .speaker: Color(red: 1.0, green: 0.55, blue: 0.10)
        case .printer: Color(red: 0.10, green: 0.62, blue: 0.95)
        case .camera: Color(red: 0.93, green: 0.26, blue: 0.26)
        case .gameConsole: Color(red: 0.95, green: 0.70, blue: 0.0)
        case .smartHome: Color(red: 0.98, green: 0.45, blue: 0.20)
        case .iot: Color(red: 0.20, green: 0.70, blue: 0.70)
        case .virtualMachine: Color(red: 0.50, green: 0.50, blue: 0.55)
        case .unknown: Color(red: 0.55, green: 0.57, blue: 0.62)
        }
    }
}

extension NetworkInterface.Kind {
    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "cable.connector.horizontal"
        case .bridge: "point.3.filled.connected.trianglepath.dotted"
        case .vpn: "lock.shield"
        case .other: "network"
        }
    }
}

/// Rounded gradient tile with the device-kind glyph.
struct DeviceIcon: View {
    let kind: DeviceKind
    var size: CGFloat = 28
    var isOnline: Bool? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [kind.color.opacity(0.85), kind.color], startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .frame(width: size, height: size)
            .saturation(isOnline == false ? 0.15 : 1)
            .opacity(isOnline == false ? 0.65 : 1)
            .overlay(alignment: .bottomTrailing) {
                if let isOnline, size >= 28 {
                    Circle()
                        .fill(isOnline ? Color.green : Color.gray)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: max(1.5, size * 0.05)))
                        .offset(x: size * 0.08, y: size * 0.08)
                }
            }
    }
}

struct StatusDot: View {
    let isOnline: Bool

    var body: some View {
        Circle()
            .fill(isOnline ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: 8, height: 8)
            .shadow(color: isOnline ? .green.opacity(0.6) : .clear, radius: 3)
            .help(isOnline ? String(localized: "Online") : String(localized: "Offline"))
            .accessibilityLabel(isOnline ? String(localized: "Online") : String(localized: "Offline"))
    }
}

/// "<1 ms", "8 ms" – one format everywhere latency is shown.
func latencyString(_ ms: Double) -> String {
    ms < 1 ? "<1 ms" : String(format: "%.0f ms", ms)
}

func latencyColor(_ ms: Double) -> Color {
    switch ms {
    case ..<20: .green
    case ..<80: .mint
    case ..<200: .orange
    default: .red
    }
}

struct LatencyText: View {
    let latency: Double?

    var body: some View {
        if let latency {
            Text(verbatim: latencyString(latency))
                .monospacedDigit()
                .foregroundStyle(latencyColor(latency))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

struct Chip: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

/// A labelled value with a copy button that appears on hover.
struct InfoRow: View {
    let label: String
    let value: String?
    var monospaced = false

    @State private var hovering = false

    var body: some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                HStack(spacing: 6) {
                    Text(value)
                        .font(monospaced ? .body.monospaced() : .body)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .truncationMode(.middle)
                    Button {
                        DeviceActions.copy(value)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                    .opacity(hovering ? 1 : 0)
                }
            }
            .onHover { hovering = $0 }
        }
    }
}

struct LatencyChart: View {
    let values: [Double]

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("#", index), y: .value("ms", value))
                    .foregroundStyle(LinearGradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("#", index), y: .value("ms", value))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            // Sub-millisecond LAN latencies need a decimal, or every label reads "0".
            let fine = (values.max() ?? 0) < 10
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(verbatim: String(format: fine ? "%.1f" : "%.0f", v)) }
                }
            }
        }
    }
}

extension Date {
    var relativeText: String {
        let seconds = -timeIntervalSinceNow
        if seconds < 60 { return String(localized: "Just now") }
        return formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// Font scaling for the device list (View ▸ Make Text Bigger/Smaller).
private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    var textScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}
