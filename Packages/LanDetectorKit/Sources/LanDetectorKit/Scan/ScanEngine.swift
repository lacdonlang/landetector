import Foundation
import Synchronization

public struct ScanOptions: Sendable, Codable, Hashable {
    /// `nil` scans the interface subnet.
    public var range: IPv4Range?
    public var maxHosts: Int = 4096
    public var useMDNS = true
    public var useNetBIOS = true
    public var useDNS = true
    public var useSSDP = true
    public var useIPv6 = true
    /// Multiplier for waits/timeouts (0.6 = fast, 1 = normal, 2 = thorough).
    public var thoroughness: Double = 1
    /// Asked for names the system resolver does not know, e.g. the router that leases out the scanned range.
    public var extraDNSServers: [IPv4Address] = []

    public init() {}
}

/// Runs a full discovery pass and streams results.
///
/// Pipeline: an ICMP sweep plus ARP polling find hosts; every new host is immediately
/// handed to the NetBIOS, mDNS and reverse-DNS probers, while SSDP/UPnP and IPv6 multicast
/// run in parallel. The scan ends once no new information has arrived for a short while.
public final class ScanEngine: Sendable {
    public init() {}

    public func scan(_ interface: NetworkInterface, options: ScanOptions = ScanOptions()) -> AsyncStream<ScanEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Self.run(interface, options: options, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private final class State: Sendable {
        let seen = Mutex<Set<IPv4Address>>([])
        let lastActivity = Mutex<ContinuousClock.Instant>(.now)
        let fetchedLocations = Mutex<Set<URL>>([])
        let reportedNeighbors = Mutex<[IPv4Address: MACAddress]>([:])
        let outstanding = Atomic<Int>(0)

        func touch() { lastActivity.withLock { $0 = .now } }
        func isNew(_ ip: IPv4Address) -> Bool { seen.withLock { $0.insert(ip).inserted } }
        /// Neighbour entries not reported yet this scan (or whose MAC changed): the ARP cache is polled repeatedly.
        func unreported(_ entries: [ARPEntry]) -> [ARPEntry] {
            reportedNeighbors.withLock { reported in
                entries.filter { e in reported.updateValue(e.mac, forKey: e.ip) != e.mac }
            }
        }
    }

    private static func run(_ interface: NetworkInterface, options: ScanOptions,
                            _ out: AsyncStream<ScanEvent>.Continuation) async {
        let clock = ContinuousClock()
        let start = clock.now
        let scale = max(0.3, options.thoroughness)
        let fullRange = options.range ?? interface.subnet
        let range = fullRange.clamped(to: options.maxHosts, around: interface.ipv4)
        let hosts = Array(range)
        let context = ScanContext(interface: interface, range: range, startedAt: Date())
        // Behind a router there is no ARP, no multicast discovery, no link-local IPv6 and no reason to list this Mac
        // or its gateway.
        let local = context.isLocal
        out.yield(.started(context))
        out.yield(.progress(0, .discovery))
        // The kernel never lists our own MAC usefully (macOS masks it), so add it from IOKit.
        if local, let mac = interface.mac {
            out.yield(.neighbors([ARPEntry(ip: interface.ipv4, mac: mac, interface: interface.name,
                                           isPermanent: true, isFresh: true)], source: .sysctl))
        }

        let state = State()
        let yield: @Sendable (ScanEvent) -> Void = { event in
            state.touch()
            out.yield(event)
        }

        // Probers.
        let netbios = options.useNetBIOS ? try? NetBIOSProber(interface: interface) : nil
        let mdns = options.useMDNS ? try? MDNSProber(interface: interface) : nil
        let ssdp = options.useSSDP && local ? try? SSDPProber(interface: interface) : nil
        let icmp = try? ICMPProber()
        let icmp6 = options.useIPv6 && local && interface.ipv6LinkLocal != nil ? ICMPv6Prober(interface: interface) : nil
        let unicastDNS = options.useDNS ? UnicastDNS(servers: options.extraDNSServers) : nil

        let discovered: @Sendable (IPv4Address) -> Void = { ip in
            guard context.covers(ip), state.isNew(ip) else { return }
            netbios?.probe(ip)
            mdns?.probe(ip)
            if options.useDNS {
                state.outstanding.add(1, ordering: .relaxed)
                Task.detached {
                    var name = await ReverseDNS.lookup(ip)
                    if name == nil { name = await unicastDNS?.lookup(ip) }
                    if let name { yield(.dnsName(ip, name)) }
                    state.outstanding.subtract(1, ordering: .relaxed)
                }
            }
        }

        netbios?.start { ip, info in yield(.netbios(ip, info)) }
        mdns?.start { ip, info in
            guard context.covers(ip) else { return }
            yield(.mdns(ip, info))
            discovered(ip)
        }
        ssdp?.start { ip, response in
            guard range.contains(ip) else { return }
            yield(.ssdp(ip, response))
            discovered(ip)
            guard let location = response.location,
                  state.fetchedLocations.withLock({ $0.insert(location).inserted }) else { return }
            state.outstanding.add(1, ordering: .relaxed)
            Task.detached {
                if let info = await UPnPFetcher.fetch(location) {
                    var merged = info
                    merged.server = response.server
                    yield(.upnp(ip, merged))
                }
                state.outstanding.subtract(1, ordering: .relaxed)
            }
        }
        icmp?.start { ip, rtt in
            yield(.alive(ip, rtt: rtt))
            discovered(ip)
        }
        icmp6?.start { ip, rtt in yield(.ipv6Alive(ip, rtt: rtt)) }

        // Kick off multicast discovery while the sweep runs.
        if local {
            mdns?.browse()
            ssdp?.search()
            icmp6?.probe()
            discovered(interface.ipv4)
            if let gw = interface.gateway { discovered(gw) }
        }

        // ARP polling: picks up hosts that ignore ping.
        let neighborSource = Mutex<ARPTable.Source>(.unavailable)
        let readNeighbors: @Sendable () -> Void = {
            let (entries, source) = ARPTable.read(interface: interface.name)
            neighborSource.withLock { $0 = source }
            let fresh = state.unreported(entries.filter { $0.isFresh && context.covers($0.ip) })
            if !fresh.isEmpty {
                out.yield(.neighbors(fresh, source: source))
                for e in fresh { discovered(e.ip) }
            }
        }
        let arpPoller = local ? Task.detached {
            while !Task.isCancelled {
                readNeighbors()
                try? await Task.sleep(for: .milliseconds(450))
            }
        } : nil

        // Sweep twice: the second pass catches hosts whose first packet was lost during ARP resolution.
        await icmp?.sweep(hosts) { p in out.yield(.progress(p * 0.35, .discovery)) }
        try? await Task.sleep(for: .milliseconds(Int(500 * scale)))
        if local {
            mdns?.browse()
            ssdp?.search()
            icmp6?.probe()
        }
        if !Task.isCancelled {
            await icmp?.sweep(hosts) { p in out.yield(.progress(0.35 + p * 0.2, .discovery)) }
        }
        try? await Task.sleep(for: .milliseconds(Int(1200 * scale)))
        out.yield(.progress(0.6, .enrichment))

        // Enrichment: wait until things go quiet (or a hard deadline).
        let minimum = Duration.milliseconds(Int(3500 * scale))
        let quiet = Duration.milliseconds(Int(1500 * scale))
        let deadline = Duration.seconds(12 * scale)
        while !Task.isCancelled {
            let elapsed = clock.now - start
            let idle = clock.now - state.lastActivity.withLock { $0 }
            let pending = state.outstanding.load(ordering: .relaxed)
            if elapsed > deadline { break }
            if elapsed > minimum && idle > quiet && (pending == 0 || idle > quiet * 2) { break }
            let fraction = min(0.97, 0.6 + 0.37 * (elapsed / deadline))
            out.yield(.progress(fraction, .enrichment))
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Final neighbour tables.
        if let arpPoller {
            arpPoller.cancel()
            readNeighbors()
        }
        if options.useIPv6 && local {
            let ndp = NDPTable.read(interface: interface)
            if !ndp.isEmpty { out.yield(.ndp(ndp)) }
        }

        icmp?.close()
        icmp6?.close()
        mdns?.close()
        netbios?.close()
        ssdp?.close()
        unicastDNS?.close()

        let elapsed = clock.now - start
        out.yield(.progress(1, .finishing))
        out.yield(.finished(ScanSummary(
            duration: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            hostsProbed: hosts.count,
            neighborSource: neighborSource.withLock { $0 })))
    }
}

/// Measures latency to known hosts (used for live monitoring between full scans).
public enum LatencyProbe {
    public static func ping(_ hosts: [IPv4Address], timeout: Duration = .seconds(1)) async -> [IPv4Address: Double] {
        guard let prober = try? ICMPProber() else { return [:] }
        let results = Mutex<[IPv4Address: Double]>([:])
        prober.start { ip, rtt in results.withLock { if $0[ip] == nil { $0[ip] = rtt } } }
        await prober.sweep(hosts)
        try? await Task.sleep(for: timeout)
        prober.close()
        return results.withLock { $0 }
    }
}
