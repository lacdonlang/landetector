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
