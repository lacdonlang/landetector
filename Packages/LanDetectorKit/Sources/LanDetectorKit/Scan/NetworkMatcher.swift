import Foundation

/// What is known about one stored network, for deciding whether the current network is the same one.
public struct NetworkFingerprint: Sendable, Hashable {
    public var key: String
    public var savedAt: Date
    /// `192.168.1.0/24`; `nil` for stores written before it was recorded.
    public var subnet: String?
    /// Every gateway MAC seen on this network (a router replaced, a VM gateway recreated…).
    public var gatewayMACs: Set<MACAddress>
    public var deviceMACs: Set<MACAddress>
    public var deviceIPs: [IPv4Address]

    public init(key: String, savedAt: Date, subnet: String?, gatewayMACs: Set<MACAddress>, deviceMACs: Set<MACAddress>,
                deviceIPs: [IPv4Address]) {
        self.key = key
        self.savedAt = savedAt
        self.subnet = subnet
        self.gatewayMACs = gatewayMACs
        self.deviceMACs = deviceMACs
        self.deviceIPs = deviceIPs
    }
}

/// Recognises a network across launches.
///
/// A gateway MAC alone is fragile: routers get replaced, VM gateways get new MACs, the default route can move between
/// two routers, and at launch the ARP cache may not know the gateway yet. One router can also serve several subnets
/// (VLANs) with the same MAC. So a stored network must have the same subnet, and then either have seen the current
/// gateway or share at least two devices (this Mac excluded – it is on every network) with what the ARP cache shows
/// now. All matching stores are merged into the most recently saved one.
public enum NetworkMatcher {
    public struct Decision: Equatable, Sendable {
        /// Store to load; `nil` means this is a network not seen before.
        public var key: String?
        /// Other stores that describe the same network and should be folded into `key`.
        public var merge: [String]
    }

    public static func subnetKey(_ address: IPv4Address, netmask: IPv4Address) -> String {
        "\(IPv4Address(address.value & netmask.value))/\(netmask.value.nonzeroBitCount)"
    }

    public static func match(subnet: String, range: IPv4Range, gatewayMAC: MACAddress?, visibleMACs: Set<MACAddress>,
                             selfMAC: MACAddress?, stores: [NetworkFingerprint]) -> Decision {
        let visible = visibleMACs.subtracting(selfMAC.map { [$0] } ?? [])
        func sameSubnet(_ s: NetworkFingerprint) -> Bool {
            if let stored = s.subnet { return stored == subnet }
            // Older stores: most of their devices sit inside the current range.
            let inside = s.deviceIPs.filter(range.contains).count
            return inside > 0 && inside * 2 >= s.deviceIPs.count
        }
        let matching = stores.filter { s in
            guard sameSubnet(s) else { return false }
            if let gatewayMAC, s.gatewayMACs.contains(gatewayMAC) { return true }
            return s.deviceMACs.intersection(visible).count >= 2
        }
        if !matching.isEmpty {
            let ordered = matching.sorted { $0.savedAt > $1.savedAt }
            return Decision(key: ordered[0].key, merge: ordered.dropFirst().map(\.key))
        }
        // No evidence either way (ARP cache empty or unreadable): reuse the latest store of this subnet.
        if visible.isEmpty, let latest = stores.filter(sameSubnet).max(by: { $0.savedAt < $1.savedAt }) {
            return Decision(key: latest.key, merge: [])
        }
        return Decision(key: nil, merge: [])
    }

    /// Combines device lists of stores that turned out to be one network. Earlier lists win on conflicting values,
    /// so pass the most recently saved store first.
    public static func mergeDevices(_ lists: [[Device]]) -> [Device] {
        var byID: [String: Device] = [:]
        var order: [String] = []
        for list in lists {
            for device in list {
                if let existing = byID[device.id] {
                    byID[device.id] = DeviceInventory.merged(device, into: existing, preferSourceLatency: false)
                } else {
                    byID[device.id] = device
                    order.append(device.id)
                }
            }
        }
        return order.compactMap { byID[$0] }
    }
}
