import Foundation

/// Whether a device answered one completed scan.
public struct PresenceSample: Sendable, Hashable {
    public var date: Date
    public var online: Bool

    public init(date: Date, online: Bool) {
        // Whole seconds, as stored, so live and reloaded samples compare equal.
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        self.online = online
    }
}

extension PresenceSample: Codable {
    // Stored compactly as Unix seconds, negated when the device was offline.
    public init(from decoder: Decoder) throws {
        let seconds = try decoder.singleValueContainer().decode(Int64.self)
        self.init(date: Date(timeIntervalSince1970: TimeInterval(seconds.magnitude)), online: seconds > 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        let seconds = Int64(date.timeIntervalSince1970)
        try c.encode(online ? seconds : -seconds)
    }
}

extension Device {
    /// The presence history keeps about 30 days in at most 500 samples.
    public static let presenceRetention: TimeInterval = 30 * 86_400
    public static let presenceLimit = 500

    /// Where the current online / offline run began, if the history shows the device changing state at all.
    /// `online` is the state it changed to; `date` is the first completed scan that saw it.
    public var lastPresenceChange: PresenceSample? {
        guard let last = presence.last else { return nil }
        var start = presence.count - 1
        while start > 0, presence[start - 1].online == last.online { start -= 1 }
        return start > 0 ? presence[start] : nil
    }

    /// Appends the verdict of a completed scan.
    public mutating func recordPresence(online: Bool, at now: Date = Date()) {
        let sample = PresenceSample(date: now, online: online)
        let index = presence.lastIndex { $0.date <= sample.date }.map { $0 + 1 } ?? 0
        presence.insert(sample, at: index)
        presence = Self.compactedPresence(presence, now: now)
    }

    /// Combines the histories of two records of one device; when both judged the same scan, online wins.
    static func mergedPresence(_ a: [PresenceSample], _ b: [PresenceSample]) -> [PresenceSample] {
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty ? b : a }
        var online: [Date: Bool] = [:]
        for s in a + b { online[s.date] = online[s.date] == true || s.online }
        let merged = online.map { PresenceSample(date: $0.key, online: $0.value) }.sorted { $0.date < $1.date }
        return compactedPresence(merged, now: merged[merged.count - 1].date)
    }

    /// Drops samples past the retention window, thins steady stretches and caps the count.
    ///
    /// A sample that agrees with both neighbours marks no change, so it goes as long as the samples around it stay
    /// within 20 minutes of each other (2 hours once older than a day). Changes and gaps in observation survive,
    /// and a steady device fits the whole retention window into the limit even under live monitoring.
    static func compactedPresence(_ samples: [PresenceSample], now: Date) -> [PresenceSample] {
        let cutoff = now.addingTimeInterval(-presenceRetention)
        let recent = Array(samples.drop { $0.date < cutoff })
        guard recent.count > 2 else { return recent }
        var kept = [recent[0]]
        for i in 1..<recent.count - 1 {
            let sample = recent[i], previous = kept[kept.count - 1], next = recent[i + 1]
            let spacing: TimeInterval = now.timeIntervalSince(sample.date) < 86_400 ? 20 * 60 : 2 * 3600
            let steady = sample.online == previous.online && sample.online == next.online
            if !steady || next.date.timeIntervalSince(previous.date) > spacing { kept.append(sample) }
        }
        kept.append(recent[recent.count - 1])
        return Array(kept.suffix(presenceLimit))
    }
}
