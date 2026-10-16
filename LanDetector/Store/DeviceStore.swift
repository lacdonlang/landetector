import Foundation
import LanDetectorKit

/// Persists one device inventory per network in Application Support.
enum DeviceStore {
    struct StoredNetwork: Codable {
        var key: String
        var savedAt: Date
        var devices: [Device]
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LanDetector/Networks", isDirectory: true)
    }

    private static func url(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    static func load(key: String) -> [Device] {
        guard let data = try? Data(contentsOf: url(for: key)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(StoredNetwork.self, from: data))?.devices ?? []
    }

    static func save(key: String, devices: [Device]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(StoredNetwork(key: key, savedAt: Date(), devices: devices)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Identifies "the same network" across launches by the gateway's MAC address.
enum NetworkIdentity {
    static func key(for interface: NetworkInterface) async -> String {
        if let gateway = interface.gateway {
            for attempt in 0..<3 {
                if let mac = ARPTable.read(interface: interface.name).entries.first(where: { $0.ip == gateway })?.mac {
                    return "gw-\(mac)"
                }
                if attempt == 0 { _ = await LatencyProbe.ping([gateway], timeout: .milliseconds(300)) }
            }
            return "net-\(interface.subnet.lower)-\(interface.prefixLength)-gw-\(gateway)"
        }
        return "net-\(interface.subnet.lower)-\(interface.prefixLength)"
    }
}

/// Export / import of user-defined names (LanScan's "Import/Export Custom Names").
struct CustomNameRecord: Codable {
    var mac: String?
    var ip: String?
    var name: String?
    var notes: String?
    var kind: String?
    var url: String?
    var favorite: Bool?
}
