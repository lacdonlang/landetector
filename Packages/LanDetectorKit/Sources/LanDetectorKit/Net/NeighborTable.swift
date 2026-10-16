import Darwin
import Foundation
import IOKit

/// An IPv4 → MAC mapping from the kernel ARP cache.
public struct ARPEntry: Hashable, Sendable {
    public let ip: IPv4Address
    public let mac: MACAddress
    public let interface: String
    /// Static/self entries without expiry.
    public let isPermanent: Bool
    /// `true` when the kernel heard from the neighbour recently (entry not expired).
    public let isFresh: Bool
}

/// An IPv6 → MAC mapping from the kernel neighbour discovery cache.
public struct NDPEntry: Hashable, Sendable {
    public let ip: IPv6Address
    public let mac: MACAddress
    public let interfaceIndex: UInt32
}

public enum ARPTable {
    /// Where the last read came from – macOS 27 hides ARP entries from `sysctl` for
    /// non-platform processes, in which case we fall back to `/usr/sbin/arp`.
    public enum Source: String, Sendable { case sysctl, arpCommand, unavailable }

    private static let sourceLock = NSLock()
    nonisolated(unsafe) private static var preferCommand = false

    public static func read(interface: String? = nil) -> (entries: [ARPEntry], source: Source) {
        sourceLock.lock()
        let useCommand = preferCommand
        sourceLock.unlock()

        if !useCommand, let entries = readSysctl(), !entries.isEmpty {
            return (filter(entries, interface), .sysctl)
        }
        if let entries = readCommand() {
            sourceLock.lock()
            preferCommand = true
            sourceLock.unlock()
            return (filter(entries, interface), .arpCommand)
        }
        return ([], .unavailable)
    }

    private static func filter(_ entries: [ARPEntry], _ interface: String?) -> [ARPEntry] {
        guard let interface else { return entries }
        return entries.filter { $0.interface == interface }
    }

    /// `sysctl(NET_RT_FLAGS, RTF_LLINFO)` – empty when the system hides neighbours from this process.
    static func readSysctl() -> [ARPEntry]? {
        var entries: [ARPEntry] = []
        let now = Int(time(nil))
        let uptime = Int(ProcessInfo.processInfo.systemUptime)
        var names: [UInt32: String] = [:]
        RoutingTable.forEachRouteMessage(family: AF_INET, flags: RTF_LLINFO) { header, addrs in
            guard case .v4(let ip)? = addrs[Int(RTAX_DST)],
                  case .link(let mac?, _)? = addrs[Int(RTAX_GATEWAY)], mac.isUsable else { return }
            let index = UInt32(header.rtm_index)
            let name = names[index] ?? {
                var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                let n = if_indextoname(index, &buf).map { String(cString: $0) } ?? "if\(index)"
                names[index] = n
                return n
            }()
            // rmx_expire is a calendar timestamp (0 = permanent); expired entries keep their
            // MAC but the neighbour has not been heard from recently.
            let expire = Int(header.rtm_rmx.rmx_expire)
            let permanent = expire == 0
            let fresh = permanent || expire > now || (expire < 1_000_000_000 && expire > uptime)
            entries.append(ARPEntry(ip: ip, mac: mac, interface: name, isPermanent: permanent, isFresh: fresh))
        }
        return entries
    }

    /// Parses `arp -anl`:
    /// `192.168.1.1   8c:96:a5:91:d0:d8 2m56s   2m10s   en0  1`
    static func readCommand() -> [ARPEntry]? {
        guard let output = ProcessRunner.run("/usr/sbin/arp", ["-anl"]) else { return nil }
        var entries: [ARPEntry] = []
        for line in output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 5, let ip = IPv4Address(String(cols[0])), let mac = MACAddress(String(cols[1])),
                  mac.isUsable else { continue }
            let expireOut = cols[2], expireIn = cols[3]
            let permanent = expireOut == "(none)"
            let fresh = permanent || expireOut != "expired" || expireIn != "expired"
            entries.append(ARPEntry(ip: ip, mac: mac, interface: String(cols[4]),
                                    isPermanent: permanent, isFresh: fresh))
        }
        return entries
    }
}

public enum NDPTable {
    public static func read(interface: NetworkInterface) -> [NDPEntry] {
        var entries: [NDPEntry] = []
        RoutingTable.forEachRoute(family: AF_INET6, flags: RTF_LLINFO) { index, _, addrs in
            guard index == interface.index, case .v6(let ip)? = addrs[Int(RTAX_DST)], !ip.isMulticast,
                  case .link(let mac?, _)? = addrs[Int(RTAX_GATEWAY)], mac.isUsable else { return }
            entries.append(NDPEntry(ip: ip, mac: mac, interfaceIndex: index))
        }
        // macOS 27 hides neighbours (and masks MACs) from sysctl – fall back to the ndp tool.
        if entries.count <= 1, let output = ProcessRunner.run("/usr/sbin/ndp", ["-an"]) {
            var parsed: [NDPEntry] = []
            for line in output.split(separator: "\n").dropFirst() {
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                guard cols.count >= 3, cols[2] == interface.name,
                      let ip = IPv6Address(String(cols[0])), !ip.isMulticast,
                      let mac = MACAddress(String(cols[1])), mac.isUsable else { continue }
                parsed.append(NDPEntry(ip: ip, mac: mac, interfaceIndex: interface.index))
            }
            if parsed.count > entries.count { entries = parsed }
        }
        return entries
    }
}

/// Reads hardware addresses from IOKit (getifaddrs returns a placeholder on macOS 27).
enum HardwareAddress {
    static func lookup(bsdName: String) -> MACAddress? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var current = service
        IOObjectRetain(current)
        // Walk up until a node carrying IOMACAddress (the IOEthernetController) is found.
        for _ in 0..<4 {
            if let data = IORegistryEntryCreateCFProperty(current, "IOMACAddress" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data, let mac = MACAddress(bytes: data), mac.isUsable {
                IOObjectRelease(current)
                return mac
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
        }
        IOObjectRelease(current)
        return nil
    }
}

/// Minimal synchronous process runner (used for `arp` / `ndp`).
enum ProcessRunner {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
