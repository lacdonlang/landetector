import Foundation
import LanDetectorKit

/// Persists one device inventory per network in Application Support.
enum DeviceStore {
    struct StoredNetwork: Codable {
        var key: String
        var savedAt: Date
        var devices: [Device]
        /// `192.168.1.0/24`; missing in files written by early versions.
        var subnet: String?
        /// Every gateway MAC seen on this network.
        var gatewayMACs: [String]?

        var fingerprint: NetworkFingerprint {
            var gateways = Set((gatewayMACs ?? []).compactMap(MACAddress.init))
            // Early versions named stores after the gateway: "gw-aa:bb:cc:dd:ee:ff".
            if key.hasPrefix("gw-"), let mac = MACAddress(String(key.dropFirst(3))) { gateways.insert(mac) }
            return NetworkFingerprint(key: key, savedAt: savedAt, subnet: subnet, gatewayMACs: gateways,
                                      deviceMACs: Set(devices.compactMap(\.mac)), deviceIPs: devices.compactMap(\.ipv4))
        }
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LanDetector/Networks", isDirectory: true)
    }

    private static func url(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load(key: String) -> StoredNetwork? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? decoder.decode(StoredNetwork.self, from: data)
    }

    /// Every stored network (merged-away backups excluded).
    static func all() -> [StoredNetwork] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(StoredNetwork.self, from: $0) }
        }
    }

    static func exists(key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    static func save(key: String, devices: [Device], subnet: String?, gatewayMACs: Set<String>) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let stored = StoredNetwork(key: key, savedAt: Date(), devices: devices, subnet: subnet,
                                   gatewayMACs: gatewayMACs.sorted())
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
    }

    /// Keeps a store that was merged into another as `<name>.json.merged` instead of deleting it.
    static func retire(key: String) {
        let source = url(for: key)
        let backup = source.appendingPathExtension("merged")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: source, to: backup)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The stored network the current interface belongs to, with its devices loaded.
struct NetworkResolution {
    var key: String
    var subnet: String
    var devices: [Device]
    var gatewayMACs: Set<String>
    /// Stores folded into `key` because they turned out to describe the same network.
    var mergedKeys: [String]
}

/// Recognises "the same network" across launches (see `NetworkMatcher`).
enum NetworkIdentity {
    /// Returns `nil` when the interface still belongs to `currentKey`, so the in-memory inventory stays authoritative.
    static func resolve(for interface: NetworkInterface, currentKey: String?) async -> NetworkResolution? {
        let gatewayMAC = await gatewayMAC(for: interface)
        // Stale ARP entries do not prove a device is online, but they do show which LAN this is.
        let visible = Set(ARPTable.read(interface: interface.name).entries.map(\.mac))
        let subnet = NetworkMatcher.subnetKey(interface.ipv4, netmask: interface.netmask)
        return await Task.detached(priority: .userInitiated) { () -> NetworkResolution? in
            let stores = DeviceStore.all()
            let decision = NetworkMatcher.match(subnet: subnet, range: interface.subnet, gatewayMAC: gatewayMAC,
                                                visibleMACs: visible, selfMAC: interface.mac,
                                                stores: stores.map(\.fingerprint))
            if let key = decision.key, key == currentKey { return nil }
            var gateways = Set(gatewayMAC.map { [$0.description] } ?? [])
            guard let key = decision.key, let primary = stores.first(where: { $0.key == key }) else {
                return NetworkResolution(key: newKey(gatewayMAC: gatewayMAC, subnet: subnet), subnet: subnet, devices: [],
                                         gatewayMACs: gateways, mergedKeys: [])
            }
            let others = decision.merge.compactMap { k in stores.first { $0.key == k } }.sorted { $0.savedAt > $1.savedAt }
            for store in [primary] + others {
                gateways.formUnion(store.fingerprint.gatewayMACs.map(\.description))
            }
            var devices = primary.devices
            if !others.isEmpty {
                devices = NetworkMatcher.mergeDevices([primary.devices] + others.map(\.devices))
                DeviceStore.save(key: key, devices: devices, subnet: subnet, gatewayMACs: gateways)
                for store in others { DeviceStore.retire(key: store.key) }
            }
            return NetworkResolution(key: key, subnet: subnet, devices: devices, gatewayMACs: gateways,
                                     mergedKeys: others.map(\.key))
        }.value
    }

    /// The stored network a range behind a router belongs to (see `NetworkMatcher.store(behind:)`), or a new, empty one.
    static func resolve(remote range: IPv4Range, from interface: NetworkInterface) async -> NetworkResolution {
        let subnet = range.coveringSubnet
        return await Task.detached(priority: .userInitiated) {
            // The local ARP cache shows the routers this Mac can see – one of them may also serve the range.
            let localMACs = Set(ARPTable.read(interface: interface.name).entries.map(\.mac))
            let stores = DeviceStore.all()
            let key = NetworkMatcher.store(behind: range, localMACs: localMACs, stores: stores.map(\.fingerprint))
            guard let store = stores.first(where: { $0.key == key }) else {
                return NetworkResolution(key: "range-\(subnet)", subnet: subnet, devices: [], gatewayMACs: [], mergedKeys: [])
            }
            return NetworkResolution(key: store.key, subnet: store.subnet ?? subnet, devices: store.devices,
                                     gatewayMACs: Set(store.fingerprint.gatewayMACs.map(\.description)), mergedKeys: [])
        }.value
    }

    /// After a full scan: other stores that turn out to be this network, given everything the scan saw.
    /// Returns their devices (newest store first) and retires them.
    static func strayStores(of key: String, interface: NetworkInterface, subnet: String, visible: Set<MACAddress>,
                            gatewayMAC: MACAddress?) async -> (devices: [Device], gatewayMACs: Set<String>, keys: [String]) {
        await Task.detached(priority: .utility) {
            // With so little to compare, "same subnet" alone could merge a different LAN.
            guard visible.subtracting(interface.mac.map { [$0] } ?? []).count >= 2 else { return ([], [], []) }
            let stores = DeviceStore.all().filter { $0.key != key }
            let decision = NetworkMatcher.match(subnet: subnet, range: interface.subnet, gatewayMAC: gatewayMAC,
                                                visibleMACs: visible, selfMAC: interface.mac,
                                                stores: stores.map(\.fingerprint))
            let keys = ([decision.key].compactMap { $0 } + decision.merge)
            let matched = keys.compactMap { k in stores.first { $0.key == k } }.sorted { $0.savedAt > $1.savedAt }
            for store in matched { DeviceStore.retire(key: store.key) }
            let gateways = Set(matched.flatMap { $0.fingerprint.gatewayMACs.map(\.description) })
            return (NetworkMatcher.mergeDevices(matched.map(\.devices)), gateways, matched.map(\.key))
        }.value
    }

    private static func gatewayMAC(for interface: NetworkInterface) async -> MACAddress? {
        guard let gateway = interface.gateway else { return nil }
        for attempt in 0..<3 {
            if let mac = ARPTable.read(interface: interface.name).entries.first(where: { $0.ip == gateway })?.mac {
                return mac
            }
            if attempt == 0 { _ = await LatencyProbe.ping([gateway], timeout: .milliseconds(300)) }
        }
        return nil
    }

    /// A key no existing store uses.
    private static func newKey(gatewayMAC: MACAddress?, subnet: String) -> String {
        if let gatewayMAC, !DeviceStore.exists(key: "gw-\(gatewayMAC)") { return "gw-\(gatewayMAC)" }
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "net-\(subnet)-\(suffix)"
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
    var watched: Bool?
}
