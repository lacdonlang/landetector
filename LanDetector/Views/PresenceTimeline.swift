import Charts
import LanDetectorKit
import SwiftUI

/// Time span of the presence strip in the inspector.
enum PresenceWindow: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: String(localized: "24 Hours")
        case .week: String(localized: "7 Days")
        case .month: String(localized: "30 Days")
        }
    }

    /// Caption under the start of the strip.
    var startCaption: String {
        switch self {
        case .day: String(localized: "24 hours ago")
        case .week: String(localized: "7 days ago")
        case .month: String(localized: "30 days ago")
        }
    }

    /// Width of one bar: 30 minutes, 4 hours, 12 hours.
    var slot: TimeInterval {
        switch self {
        case .day: 1800
        case .week: 4 * 3600
        case .month: 12 * 3600
        }
    }

    var slotCount: Int {
        switch self {
        case .day: 48
        case .week: 42
        case .month: 60
        }
    }
}

/// One bar of the strip: what the completed scans inside a time slot saw.
struct PresenceSlot: Identifiable {
    let start: Date
    let end: Date
    var online = 0
    var total = 0

    var id: Date { start }
    /// Share of the slot's scans that found the device; `nil` when no scan ran.
    var fraction: Double? { total == 0 ? nil : Double(online) / Double(total) }

    /// The window's slots up to `now`, aligned to the local clock (…, 10:00, 10:30, …).
    static func slots(_ samples: [PresenceSample], window: PresenceWindow, now: Date) -> [PresenceSlot] {
        let size = window.slot
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: now))
        let last = ((now.timeIntervalSince1970 + offset) / size).rounded(.down) * size - offset
        let first = last - size * Double(window.slotCount - 1)
        var slots = (0..<window.slotCount).map { i in
            let start = Date(timeIntervalSince1970: first + size * Double(i))
            return PresenceSlot(start: start, end: start.addingTimeInterval(size))
        }
        for sample in samples {
            let i = Int(((sample.date.timeIntervalSince1970 - first) / size).rounded(.down))
            guard slots.indices.contains(i) else { continue }
            slots[i].total += 1
            if sample.online { slots[i].online += 1 }
        }
        return slots
    }
}

/// Inspector rows for the presence history: the uptime and a strip of time slots coloured by what the scans saw.
struct PresenceTimeline: View {
    let samples: [PresenceSample]
    let window: PresenceWindow
    @State private var hovered: PresenceSlot?

    var body: some View {
        let slots = PresenceSlot.slots(samples, window: window, now: Date())
        let observed = slots.compactMap(\.fraction)
        LabeledContent("Uptime") {
            if observed.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            } else {
                Text((observed.reduce(0, +) / Double(observed.count)).formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
        }
        .help("Share of scanned time slots in which the device was online")
        VStack(alignment: .leading, spacing: 4) {
            Chart(slots) { slot in
                // Slots without a scan shrink to a stub so they never read as "offline".
                let half = slot.fraction == nil ? 0.15 : 0.5
                RectangleMark(xStart: .value("Start", slot.start.addingTimeInterval(window.slot * 0.12)),
                              xEnd: .value("End", slot.end.addingTimeInterval(-window.slot * 0.12)),
                              yStart: .value("", 0.5 - half), yEnd: .value("", 0.5 + half))
                    .foregroundStyle(color(slot).opacity(hovered == nil || hovered?.id == slot.id ? 1 : 0.55))
                    .cornerRadius(1.5)
            }
            .chartXScale(domain: slots[0].start...slots[slots.count - 1].end)
            .chartYScale(domain: 0.0...1.0)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let point) = phase, let plot = proxy.plotFrame,
                                  let date: Date = proxy.value(atX: point.x - geometry[plot].origin.x) else {
                                hovered = nil
                                return
                            }
                            hovered = slots.first { $0.start <= date && date < $0.end }
                        }
                }
            }
            .frame(height: 16)
            HStack {
                Text(hovered.map(describe) ?? window.startCaption)
                Spacer()
                if hovered == nil { Text("Now") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func color(_ slot: PresenceSlot) -> Color {
        guard let fraction = slot.fraction else { return Color.secondary.opacity(0.3) }
        return fraction == 1 ? .green : fraction == 0 ? Color.secondary.opacity(0.45) : .orange
    }

    private func describe(_ slot: PresenceSlot) -> String {
        let start = window == .day
            ? slot.start.formatted(date: .omitted, time: .shortened)
            : slot.start.formatted(.dateTime.month().day().hour().minute())
        let state = switch slot.fraction {
        case nil: String(localized: "Not scanned")
        case 1?: String(localized: "Online")
        case 0?: String(localized: "Offline")
        default: String(localized: "Partly online")
        }
        return "\(start)–\(slot.end.formatted(date: .omitted, time: .shortened)) · \(state)"
    }
}
