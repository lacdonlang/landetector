import Foundation
import Testing
@testable import LanDetectorKit

@Suite struct AddressTests {
    @Test func ipv4Parsing() {
        let ip = IPv4Address("192.168.1.20")
        #expect(ip?.description == "192.168.1.20")
        #expect(ip?.reverseDNSName == "20.1.168.192.in-addr.arpa")
        #expect(IPv4Address("300.1.1.1") == nil)
    }

    @Test func ranges() {
        let subnet = IPv4Range.subnet(address: IPv4Address("10.0.0.7")!, netmask: IPv4Address("255.255.255.0")!)
        #expect(subnet.lower.description == "10.0.0.1")
        #expect(subnet.upper.description == "10.0.0.254")
        #expect(subnet.count == 254)
        #expect(IPv4Range(string: "192.168.1.10-20")?.count == 11)
        #expect(IPv4Range(string: "192.168.1.0/30")?.count == 2)
        #expect(IPv4Range(string: "10.0.0.5 - 10.0.1.4")?.count == 256)
        let big = IPv4Range(string: "10.0.0.0/16")!
        let clamped = big.clamped(to: 1024, around: IPv4Address("10.0.200.1")!)
        #expect(clamped.count == 1024)
        #expect(clamped.contains(IPv4Address("10.0.200.1")!))
    }

    @Test func macParsing() {
        #expect(MACAddress("8c:96:a5:91:d0:d8")?.description == "8c:96:a5:91:d0:d8")
        #expect(MACAddress("1:0:5e:0:0:fb")?.description == "01:00:5e:00:00:fb")
        #expect(MACAddress("8C96.A591.D0D8")?.description == "8c:96:a5:91:d0:d8")
        #expect(MACAddress("a2:1d:5e:63:61:98")?.isLocallyAdministered == true)
        #expect(MACAddress("02:00:00:00:00:00")?.isUsable == false)
    }

    @Test func eui64() {
        #expect(IPv6Address("fe80::fa38:8dff:febd:d7e")?.eui64MAC?.description == "f8:38:8d:bd:0d:7e")
        #expect(IPv6Address("fe80::1443:f5c0:910e:9978")?.eui64MAC == nil)
        #expect(IPv6Address("fe80::1%en0")?.isLinkLocal == true)
    }
}

@Suite struct ProtocolTests {
    @Test func dnsRoundTrip() throws {
        let query = DNSCodec.query(id: 7, [DNSQuestion("_airplay._tcp.local", .ptr)])
        let message = try #require(DNSCodec.decode(query))
        #expect(message.id == 7)
        #expect(message.questions == ["_airplay._tcp.local"])
        #expect(!message.isResponse)
    }

    @Test func dnsCompressedResponse() throws {
        // Response: PTR _x._tcp.local → "My TV._x._tcp.local" using a compression pointer.
        var b: [UInt8] = [0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0]
        let nameStart = b.count
        b += [2] + Array("_x".utf8) + [4] + Array("_tcp".utf8) + [5] + Array("local".utf8) + [0]
        b += [0, 12, 0, 1, 0, 0, 0, 120]
        let rdata: [UInt8] = [5] + Array("My TV".utf8) + [0xC0, UInt8(nameStart)]
        b += [0, UInt8(rdata.count)] + rdata
        let message = try #require(DNSCodec.decode(b))
        #expect(message.answers.first?.data == .ptr("My TV._x._tcp.local"))
        #expect(MDNSProber.instanceLabel("My TV._x._tcp.local", type: "_x._tcp.local") == "My TV")
    }

    @Test func netbiosRequestEncoding() {
        let request = NetBIOSProber.request(id: 1)
        #expect(request.count == 50)
        #expect(Array(request[13..<15]) == Array("CK".utf8))
    }

    @Test func txtDictionary() {
        let dict = DNSCodec.txtDictionary(["model=MacBookPro18,3", "Flag", "md=Chromecast"])
        #expect(dict["model"] == "MacBookPro18,3")
        #expect(dict["flag"] == "")
        #expect(dict["md"] == "Chromecast")
    }

    @Test func portParsing() {
        #expect(PortScanner.parsePorts("22, 80,8000-8002;443") == [22, 80, 443, 8000, 8001, 8002])
    }
}

@Suite struct DataTests {
    @Test func vendorLookup() {
        #expect(OUIDatabase.shared.vendor(for: MACAddress("60:3e:5f:38:65:21")!) == "Apple, Inc.")
        #expect(OUIDatabase.shortName("Apple, Inc.") == "Apple")
        #expect(OUIDatabase.shortName("Hon Hai Precision Ind. Co.,Ltd.") == "Foxconn")
        #expect(OUIDatabase.shortName("Proxmox Server Solutions GmbH") == "Proxmox")
    }

    @Test func appleModels() {
        #expect(AppleModelDatabase.shared.model(for: "iPhone15,2")?.name == "iPhone 14 Pro")
        #expect(PortDatabase.shared.service(for: 62078) != nil)
    }

    @Test func classifier() {
        var d = Device(id: "x", mac: MACAddress("60:3e:5f:38:65:21"))
        d.vendorFull = "Apple, Inc."
        d.services = [BonjourService(type: "_device-info._tcp", name: "x", port: 0, txt: ["model": "Mac14,2"])]
        let id = DeviceClassifier.identify(d)
        #expect(id.kind == .laptop)
        #expect(id.model == "MacBook Air (M2, 2022)")

        var printer = Device(id: "p")
        printer.services = [BonjourService(type: "_ipp._tcp", name: "Office", port: 631, txt: ["ty": "HP LaserJet M404"])]
        #expect(DeviceClassifier.identify(printer).kind == .printer)

        var phone = Device(id: "y")
        phone.mdnsName = "Johns-iPhone.local"
        phone.vendorFull = "Apple, Inc."
        let p = DeviceClassifier.identify(phone)
        #expect(p.kind == .phone)
        #expect(p.model == "iPhone")

        // A Xiaomi vendor alone suggests a phone; the MIoT host name says air purifier.
        var purifier = Device(id: "z")
        purifier.dnsName = "zhimi-airp-sa4_mibtAC1B"
        purifier.vendorFull = "Xiaomi Communications Co Ltd"
        #expect(DeviceClassifier.identify(purifier).kind == .smartHome)

        // Host name and vendor tie (router vs network device): the host name, checked first, decides.
        var router = Device(id: "r")
        router.dnsName = "router.h3c.com"
        router.vendorFull = "New H3C Technologies Co., Ltd"
        #expect(DeviceClassifier.identify(router).kind == .router)
    }

    @Test func inventoryMergesPlaceholder() {
        let iface = NetworkInterface(name: "en0", index: 1, displayName: "Wi-Fi", kind: .wifi, mac: nil,
                                     ipv4: IPv4Address("10.0.0.2")!, netmask: IPv4Address("255.255.255.0")!,
                                     gateway: IPv4Address("10.0.0.1"), ipv6: [])
        var inv = DeviceInventory()
        inv.apply(.started(ScanContext(interface: iface, range: iface.subnet, startedAt: Date())))
        inv.apply(.alive(IPv4Address("10.0.0.5")!, rtt: 3))
        inv.apply(.mdns(IPv4Address("10.0.0.5")!, MDNSHostInfo(hostname: "tv.local")))
        #expect(inv.devices.keys.contains("ip:10.0.0.5"))
        let mac = MACAddress("aa:bb:cc:dd:ee:01")!
        inv.apply(.neighbors([ARPEntry(ip: IPv4Address("10.0.0.5")!, mac: mac, interface: "en0", isPermanent: false, isFresh: true)],
                             source: .arpCommand))
        #expect(inv.devices.count == 1)
        let d = inv.devices["mac:aa:bb:cc:dd:ee:01"]
        #expect(d?.mdnsName == "tv.local")
        #expect(d?.latency == 3)
        #expect(d?.isOnline == true)
    }
}

@Suite struct PresenceTests {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func completedScansRecordPresence() {
        let iface = NetworkInterface(name: "en0", index: 1, displayName: "Wi-Fi", kind: .wifi, mac: nil,
                                     ipv4: IPv4Address("10.0.0.2")!, netmask: IPv4Address("255.255.255.0")!,
                                     gateway: IPv4Address("10.0.0.1"), ipv6: [])
        var inv = DeviceInventory()
        func scan(_ alive: [String], range: IPv4Range? = nil, at offset: TimeInterval, cancelled: Bool = false) {
            let now = t0.addingTimeInterval(offset)
            inv.apply(.started(ScanContext(interface: iface, range: range ?? iface.subnet, startedAt: now)), now: now)
            for ip in alive { inv.apply(.alive(IPv4Address(ip)!, rtt: 1), now: now) }
            inv.finishScan(now: now, cancelled: cancelled)
        }
        scan(["10.0.0.5", "10.0.0.9"], at: 0)
        scan(["10.0.0.5"], at: 3600)
        inv.finishScan(now: t0.addingTimeInterval(3700)) // a scan is recorded once
        scan([], range: IPv4Range(string: "10.0.0.100-120"), at: 7200) // neither device was looked for
        scan([], at: 10_800, cancelled: true)
        #expect(inv.devices["ip:10.0.0.5"]?.presence.map(\.online) == [true, true])
        #expect(inv.devices["ip:10.0.0.5"]?.presence.map(\.date) == [t0, t0.addingTimeInterval(3600)])
        #expect(inv.devices["ip:10.0.0.9"]?.presence.map(\.online) == [true, false])
    }

    @Test func presenceHistoryStaysCompact() {
        // Live monitoring every 5 minutes for 40 days, with a one-hour outage on day 35.
        var d = Device(id: "x")
        let steps = 40 * 288, outage = (35 * 288)..<(35 * 288 + 12)
        for step in 0..<steps {
            d.recordPresence(online: !outage.contains(step), at: t0.addingTimeInterval(Double(step) * 300))
        }
        let end = t0.addingTimeInterval(Double(steps - 1) * 300)
        let history = d.presence
        #expect(history.count <= Device.presenceLimit)
        #expect(history.first.map { $0.date >= end.addingTimeInterval(-Device.presenceRetention) } == true)
        #expect(history.last?.date == end)
        // Both edges of the outage survive the thinning.
        for (step, online) in [(outage.lowerBound - 1, true), (outage.lowerBound, false),
                               (outage.upperBound - 1, false), (outage.upperBound, true)] {
            #expect(history.contains(PresenceSample(date: t0.addingTimeInterval(Double(step) * 300), online: online)))
        }
        // Observed stretches keep samples close: 20 minutes apart over the last day, 2 hours before.
        for (a, b) in zip(history, history.dropFirst()) {
            let limit: TimeInterval = end.timeIntervalSince(a.date) < 86_400 ? 20 * 60 : 2 * 3600
            #expect(b.date.timeIntervalSince(a.date) <= limit)
        }
    }

    @Test func presenceCodingAndMerging() throws {
        var a = Device(id: "mac:aa:bb:cc:dd:ee:01")
        a.recordPresence(online: true, at: t0)
        a.recordPresence(online: false, at: t0.addingTimeInterval(600.7))
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        #expect(json.contains(#""presence":[1760000000,-1760000600]"#))
        #expect(try JSONDecoder().decode(Device.self, from: Data(json.utf8)).presence == a.presence)
        // Stores written before the history existed still load.
        let legacy = try JSONDecoder().decode(Device.self, from: Data(#"{"id":"ip:10.0.0.9"}"#.utf8))
        #expect(legacy.presence.isEmpty)
        // Two records of one device: where both judged the same scan, online wins.
        var b = Device(id: "ip:10.0.0.9")
        b.recordPresence(online: true, at: t0.addingTimeInterval(600))
        b.recordPresence(online: true, at: t0.addingTimeInterval(3600))
        let merged = DeviceInventory.merged(b, into: a).presence
        #expect(merged.map(\.online) == [true, true, true])
        #expect(merged.map(\.date) == [0, 600, 3600].map { t0.addingTimeInterval($0) })
    }
}

@Suite struct WatchTests {
    private func device(_ states: [Bool]) -> Device {
        var d = Device(id: "w")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        d.presence = states.enumerated().map { PresenceSample(date: start.addingTimeInterval(Double($0.offset) * 60), online: $0.element) }
        return d
    }

    @Test func lastPresenceChangeFindsStartOfCurrentRun() throws {
        #expect(device([]).lastPresenceChange == nil)
        #expect(device([true, true, true]).lastPresenceChange == nil)
        let wentOffline = try #require(device([true, true, false, false]).lastPresenceChange)
        #expect(wentOffline.online == false)
        #expect(wentOffline.date == Date(timeIntervalSince1970: 1_800_000_000 + 120))
        let cameBack = try #require(device([true, false, true]).lastPresenceChange)
        #expect(cameBack.online == true)
        #expect(cameBack.date == Date(timeIntervalSince1970: 1_800_000_000 + 120))
    }

    @Test func watchFlagIsStoredAndMerged() throws {
        var d = Device(id: "mac:aa:bb:cc:dd:ee:02", mac: MACAddress("aa:bb:cc:dd:ee:02"))
        #expect(d.isWatched == false)
        d.isWatched = true
        let decoded = try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(d))
        #expect(decoded.isWatched)
        // Records written before the flag existed decode as unwatched.
        let legacy = try JSONDecoder().decode(Device.self, from: Data(#"{"id":"x"}"#.utf8))
        #expect(legacy.isWatched == false)
        #expect(DeviceInventory.merged(d, into: Device(id: "other")).isWatched)
    }
}

@Suite struct NetworkMatcherTests {
    private let range = IPv4Range(string: "192.168.99.0/24")!
    private let me = MACAddress("60:3e:5f:38:65:21")!
    private func mac(_ n: UInt64) -> MACAddress { MACAddress(value: 0xF838_8DBD_0D00 + n) }
    private func store(_ key: String, _ age: TimeInterval, subnet: String? = "192.168.99.0/24", gateways: [MACAddress] = [],
                       macs: [MACAddress], ips: [String] = []) -> NetworkFingerprint {
        NetworkFingerprint(key: key, savedAt: Date(timeIntervalSinceNow: -age), subnet: subnet, gatewayMACs: Set(gateways),
                           deviceMACs: Set(macs), deviceIPs: ips.compactMap(IPv4Address.init))
    }
    private func decide(gateway: MACAddress?, visible: [MACAddress], _ stores: [NetworkFingerprint]) -> NetworkMatcher.Decision {
        NetworkMatcher.match(subnet: "192.168.99.0/24", range: range, gatewayMAC: gateway, visibleMACs: Set(visible),
                             selfMAC: me, stores: stores)
    }

    @Test func subnetKeyUsesTheNetworkAddress() {
        #expect(NetworkMatcher.subnetKey(IPv4Address("192.168.99.12")!, netmask: IPv4Address("255.255.255.0")!) == "192.168.99.0/24")
    }

    @Test func knownGatewayWins() {
        let d = decide(gateway: mac(1), visible: [], [store("a", 100, gateways: [mac(1)], macs: [mac(5)])])
        #expect(d == .init(key: "a", merge: []))
    }

    @Test func oneRouterServingTwoSubnetsKeepsThemApart() {
        // The H3C router is the gateway of 192.168.77.0/24 and just a device (or the gateway) on 192.168.99.0/24.
        let other = store("vlan-77", 10, subnet: "192.168.77.0/24", gateways: [mac(1)], macs: [mac(1), mac(2), mac(3)])
        #expect(decide(gateway: mac(1), visible: [mac(1), mac(2), mac(3)], [other]) == .init(key: nil, merge: []))
    }

    @Test func newGatewayMACStillFindsTheNetworkByItsDevices() {
        // The VM gateway was recreated with a new MAC; the access points are the same.
        let stores = [store("old-gw", 50, gateways: [mac(1)], macs: [mac(2), mac(3), mac(4), me]),
                      store("fallback", 10, macs: [mac(2), mac(3), me]),
                      store("other-lan", 5, subnet: "10.0.0.0/24", macs: [mac(2), mac(3)])]
        let d = decide(gateway: mac(9), visible: [mac(2), mac(3), mac(4), me], stores)
        #expect(d == .init(key: "fallback", merge: ["old-gw"]))
    }

    @Test func sameSubnetWithoutSharedDevicesIsADifferentNetwork() {
        // A café on 192.168.99.0/24: only this Mac is on both networks.
        let d = decide(gateway: mac(9), visible: [mac(7), me], [store("home", 10, gateways: [mac(1)], macs: [mac(2), mac(3), me])])
        #expect(d == .init(key: nil, merge: []))
    }

    @Test func withoutEvidenceTheLatestStoreOfTheSubnetIsReused() {
        let d = decide(gateway: nil, visible: [], [store("old", 100, macs: [mac(2)]), store("new", 10, macs: [mac(3)]),
                                                   store("elsewhere", 1, subnet: "10.0.0.0/24", macs: [])])
        #expect(d == .init(key: "new", merge: []))
    }

    @Test func legacyStoresAreMatchedByTheirDeviceAddresses() {
        let legacy = store("legacy", 10, subnet: nil, macs: [mac(2), mac(3)], ips: ["192.168.99.1", "192.168.99.2", "10.0.0.9"])
        #expect(decide(gateway: nil, visible: [mac(2), mac(3)], [legacy]) == .init(key: "legacy", merge: []))
    }

    @Test func mergingKeepsTheNewestValuesAndTheOldestHistory() {
        var newer = Device(id: "mac:aa:bb:cc:dd:ee:03", mac: MACAddress("aa:bb:cc:dd:ee:03"), now: Date(timeIntervalSince1970: 2_000))
        newer.customName = "客厅电视"
        var older = Device(id: "mac:aa:bb:cc:dd:ee:03", mac: MACAddress("aa:bb:cc:dd:ee:03"), now: Date(timeIntervalSince1970: 1_000))
        older.customName = "电视"
        older.notes = "在客厅"
        let onlyOld = Device(id: "mac:aa:bb:cc:dd:ee:04", mac: MACAddress("aa:bb:cc:dd:ee:04"))
        let merged = NetworkMatcher.mergeDevices([[newer], [older, onlyOld]])
        #expect(merged.count == 2)
        let tv = merged.first { $0.id == newer.id }
        #expect(tv?.customName == "客厅电视")
        #expect(tv?.notes == "在客厅")
        #expect(tv?.firstSeen == Date(timeIntervalSince1970: 1_000))
    }
}

@Suite struct AbsorbTests {
    @Test func absorbedHistoryNeverStealsCurrentAddresses() {
        let iface = NetworkInterface(name: "en0", index: 1, displayName: "Wi-Fi", kind: .wifi, mac: nil,
                                     ipv4: IPv4Address("10.0.0.2")!, netmask: IPv4Address("255.255.255.0")!,
                                     gateway: IPv4Address("10.0.0.1"), ipv6: [])
        var inv = DeviceInventory()
        inv.apply(.started(ScanContext(interface: iface, range: iface.subnet, startedAt: Date())))
        let current = MACAddress("aa:bb:cc:dd:ee:10")!
        inv.apply(.neighbors([ARPEntry(ip: IPv4Address("10.0.0.1")!, mac: current, interface: "en0", isPermanent: false,
                                       isFresh: true)], source: .arpCommand))
        inv.apply(.alive(IPv4Address("10.0.0.1")!, rtt: 2))

        // The old gateway (a VM that has since been recreated) used the same address.
        var oldGateway = Device(id: "mac:aa:bb:cc:dd:ee:11", mac: MACAddress("aa:bb:cc:dd:ee:11"), ipv4: IPv4Address("10.0.0.1"))
        oldGateway.customName = "旧网关"
        var sameDevice = Device(id: Device.key(for: current), mac: current, ipv4: IPv4Address("10.0.0.1"),
                                now: Date(timeIntervalSince1970: 1_000))
        sameDevice.notes = "机房"
        sameDevice.latency = 99
        inv.absorb([oldGateway, sameDevice])

        #expect(inv.devices.count == 2)
        #expect(inv.device(forIP: IPv4Address("10.0.0.1")!)?.mac == current)
        let merged = inv.devices[Device.key(for: current)]
        #expect(merged?.notes == "机房")
        #expect(merged?.latency == 2)
        #expect(merged?.firstSeen == Date(timeIntervalSince1970: 1_000))
        #expect(inv.devices["mac:aa:bb:cc:dd:ee:11"]?.isOnline == false)
    }
}

@Suite struct SharedAddressTests {
    @Test func theNewestRecordOwnsARememberedAddressAndOnlyItIsTheGateway() {
        let ip = IPv4Address("10.0.0.1")!
        var oldVM = Device(id: "mac:aa:bb:cc:dd:ee:21", mac: MACAddress("aa:bb:cc:dd:ee:21"), ipv4: ip,
                           now: Date(timeIntervalSince1970: 1_000))
        oldVM.isGateway = true
        let newVM = Device(id: "mac:aa:bb:cc:dd:ee:22", mac: MACAddress("aa:bb:cc:dd:ee:22"), ipv4: ip,
                           now: Date(timeIntervalSince1970: 2_000))
        // Insertion order must not matter.
        var inv = DeviceInventory(devices: [newVM, oldVM])
        #expect(inv.device(forIP: ip)?.id == newVM.id)

        let iface = NetworkInterface(name: "en0", index: 1, displayName: "Wi-Fi", kind: .wifi, mac: nil,
                                     ipv4: IPv4Address("10.0.0.2")!, netmask: IPv4Address("255.255.255.0")!,
                                     gateway: ip, ipv6: [])
        inv.apply(.started(ScanContext(interface: iface, range: iface.subnet, startedAt: Date())))
        inv.apply(.alive(ip, rtt: 1))
        #expect(inv.devices[newVM.id]?.isOnline == true)
        #expect(inv.devices[oldVM.id]?.isOnline == false)
        #expect(inv.devices[newVM.id]?.isGateway == true)
        #expect(inv.devices[oldVM.id]?.isGateway == false)
    }
}

@Suite struct RemoteRangeTests {
    private let here = NetworkInterface(name: "en0", index: 1, displayName: "Wi-Fi", kind: .wifi,
                                        mac: MACAddress("60:3e:5f:38:65:21"), ipv4: IPv4Address("192.168.99.12")!,
                                        netmask: IPv4Address("255.255.255.0")!, gateway: IPv4Address("192.168.99.253"),
                                        ipv6: [])
    private let behindRouter = IPv4Range(string: "192.168.77.1/24")!

    @Test func coveringSubnet() {
        #expect(behindRouter.coveringSubnet == "192.168.77.0/24")
        #expect(IPv4Range(string: "10.0.0.5-10.0.0.9")!.coveringSubnet == "10.0.0.0/28")
        #expect(IPv4Range(string: "10.0.0.5")!.coveringSubnet == "10.0.0.5/32")
        #expect(IPv4Address(prefixLength: 24) == IPv4Address("255.255.255.0"))
        #expect(IPv4Address(prefixLength: 0).value == 0 && IPv4Address(prefixLength: 32).value == .max)
    }

    @Test func onlyRangesOutsideTheSubnetAreRemote() {
        let remote = ScanContext(interface: here, range: behindRouter, startedAt: Date())
        #expect(!remote.isLocal)
        #expect(remote.covers(IPv4Address("192.168.77.20")!))
        #expect(!remote.covers(here.ipv4) && !remote.covers(here.gateway!))
        // A local range also reports this Mac and its gateway, even outside the range.
        let part = ScanContext(interface: here, range: IPv4Range(string: "192.168.99.100-200")!, startedAt: Date())
        #expect(part.isLocal)
        #expect(part.covers(here.ipv4) && part.covers(here.gateway!))
        #expect(!part.covers(IPv4Address("192.168.99.50")!))
    }

    @Test func historyAnswersForAddressesBehindARouter() {
        let switchMAC = MACAddress("dc:65:55:a7:b8:71")!
        var known = Device(id: Device.key(for: switchMAC), mac: switchMAC, ipv4: IPv4Address("192.168.77.2"),
                           now: Date(timeIntervalSinceNow: -864_000))
        known.dnsName = "BS224R_B871"
        var inv = DeviceInventory(devices: [known])
        inv.apply(.started(ScanContext(interface: here, range: behindRouter, startedAt: Date())))
        inv.apply(.alive(IPv4Address("192.168.77.2")!, rtt: 4))
        // This Mac and its gateway belong to another network.
        inv.apply(.alive(here.ipv4, rtt: 0.1))
        inv.apply(.alive(here.gateway!, rtt: 1))
        inv.apply(.neighbors([ARPEntry(ip: here.ipv4, mac: here.mac!, interface: "en0", isPermanent: true, isFresh: true)],
                             source: .sysctl))
        inv.finishScan()
        #expect(inv.devices.count == 1)
        #expect(inv.devices[known.id]?.isOnline == true)
        #expect(inv.devices[known.id]?.latency == 4)
        #expect(inv.devices[known.id]?.dnsName == "BS224R_B871")
    }

    @Test func storeOfTheSubnetBehindTheRouter() {
        let h3c = MACAddress("8c:96:a5:91:d0:d8")!
        func store(_ key: String, _ age: TimeInterval, subnet: String?, gateways: [MACAddress] = [],
                   ips: [String]) -> NetworkFingerprint {
            NetworkFingerprint(key: key, savedAt: Date(timeIntervalSinceNow: -age), subnet: subnet,
                               gatewayMACs: Set(gateways), deviceMACs: [], deviceIPs: ips.compactMap(IPv4Address.init))
        }
        let legacy = store("gw-h3c", 900, subnet: nil, gateways: [h3c], ips: ["192.168.77.1", "192.168.77.2", "192.168.77.80"])
        let home = store("home", 10, subnet: "192.168.99.0/24", ips: ["192.168.99.1", "192.168.77.5"])
        let elsewhere = store("other-77", 50, subnet: "192.168.77.0/24", ips: ["192.168.77.9"])
        // The router this Mac sees on its own LAN serves the range: its store beats a newer one of the same subnet.
        #expect(NetworkMatcher.store(behind: behindRouter, localMACs: [h3c], stores: [legacy, home, elsewhere]) == "gw-h3c")
        #expect(NetworkMatcher.store(behind: behindRouter, localMACs: [], stores: [legacy, home, elsewhere]) == "other-77")
        #expect(NetworkMatcher.store(behind: IPv4Range(string: "192.168.77.10-20")!, localMACs: [], stores: [elsewhere])
                == "other-77")
        #expect(NetworkMatcher.store(behind: IPv4Range(string: "192.168.0.0/16")!, localMACs: [], stores: [elsewhere, home])
                == nil)
    }

    @Test func leftoversOfEarlierRangeScansAreDropped() {
        let stray = Device(id: "ip:192.168.77.9", ipv4: IPv4Address("192.168.77.9"), now: Date())
        var named = Device(id: "ip:192.168.77.14", ipv4: IPv4Address("192.168.77.14"), now: Date())
        named.customName = "NAS"
        let roaming = Device(id: "mac:aa:bb:cc:dd:ee:31", mac: MACAddress("aa:bb:cc:dd:ee:31"),
                             ipv4: IPv4Address("192.168.77.3"), now: Date())
        let local = Device(id: "ip:192.168.99.40", ipv4: IPv4Address("192.168.99.40"), now: Date())
        let kept = NetworkMatcher.removingRemoteLeftovers([stray, named, roaming, local], subnet: here.subnet).map(\.id)
        #expect(kept == [named.id, roaming.id, local.id])
    }

    @Test func unicastQueriesAskForRecursion() {
        let query = DNSCodec.query(id: 7, recursionDesired: true, [DNSQuestion("2.77.168.192.in-addr.arpa", .ptr)])
        #expect(query[2] == 0x01 && query[3] == 0x00)
        #expect(DNSCodec.query([DNSQuestion("x.local", .ptr)])[2] == 0)
    }
}
