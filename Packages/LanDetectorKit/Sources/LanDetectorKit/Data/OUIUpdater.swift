import Foundation

/// Downloads the IEEE registries and writes an updated `oui.tsv` into Application Support.
public enum OUIUpdater {
    static let sources = [
        "https://standards-oui.ieee.org/oui/oui.csv",
        "https://standards-oui.ieee.org/oui28/mam.csv",
        "https://standards-oui.ieee.org/oui36/oui36.csv",
        "https://standards-oui.ieee.org/iab/iab.csv",
        "https://standards-oui.ieee.org/cid/cid.csv",
    ]

    public enum UpdateError: LocalizedError {
        case download(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .download(let url): String(localized: "Couldn’t download \(url)", bundle: .module)
            case .empty: String(localized: "The downloaded data is empty.", bundle: .module)
            }
        }
    }

    /// Returns the number of prefixes written.
    public static func update() async throws -> Int {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        // The IEEE server rejects requests without a browser-like user agent.
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
        ]
        let session = URLSession(configuration: config)
        var entries: [String: String] = [:]
        for source in sources {
            guard let url = URL(string: source) else { continue }
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download(source) }
            for row in parseCSV(String(decoding: data, as: UTF8.self)).dropFirst() where row.count >= 3 {
                let prefix = row[1].trimmingCharacters(in: .whitespaces).uppercased()
                let name = row[2].split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !prefix.isEmpty, !name.isEmpty, name.lowercased() != "private",
                      name != "IEEE Registration Authority", entries[prefix] == nil else { continue }
                entries[prefix] = name
            }
        }
        guard entries.count > 10_000 else { throw UpdateError.empty }
        let text = entries.keys.sorted().map { "\($0)\t\(entries[$0]!)" }.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: DataFiles.userDirectory, withIntermediateDirectories: true)
        try text.write(to: DataFiles.userDirectory.appendingPathComponent("oui.tsv"), atomically: true, encoding: .utf8)
        return entries.count
    }

    /// RFC 4180 CSV parser (quoted fields, escaped quotes, embedded newlines).
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        while let c = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r" {
                if c == "\r", let next = iterator.next(), next != "\n" { pending = next }
                row.append(field)
                field = ""
                rows.append(row)
                row = []
            } else {
                field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
