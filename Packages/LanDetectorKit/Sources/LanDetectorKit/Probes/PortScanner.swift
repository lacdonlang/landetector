import Darwin
import Foundation
import Synchronization

public struct PortTarget: Hashable, Sendable {
    public let ip: IPv4Address
    public let port: UInt16

    public init(ip: IPv4Address, port: UInt16) {
        self.ip = ip
        self.port = port
    }
}

/// High-concurrency TCP connect() scanner driven by kqueue on a dedicated thread.
public enum PortScanner {
    public struct Options: Sendable {
        public var concurrency: Int
        public var timeout: Duration

        public init(concurrency: Int = 384, timeout: Duration = .milliseconds(900)) {
            self.concurrency = concurrency
            self.timeout = timeout
        }

        /// Timeout derived from the measured round trip time; more parallelism for big port lists.
        public static func adaptive(portCount: Int, rtt: Double?) -> Options {
            let ms = rtt.map { min(1500, max(400, $0 * 6 + 250)) } ?? 900
            let concurrency = portCount > 2000 ? 640 : 384
            return Options(concurrency: concurrency, timeout: .milliseconds(Int(ms)))
        }
    }

    /// Scans all targets; `onOpen` and `onProgress(done, total)` are called from the scanner thread.
    public static func scan(_ targets: [PortTarget], options: Options = Options(),
                            onOpen: @escaping @Sendable (PortTarget) -> Void,
                            onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> [PortTarget] {
        let cancelled = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let thread = Thread {
                    var result = run(targets, options: options, cancelled: cancelled, onOpen: onOpen, onProgress: onProgress)
                    // Hosts and kernels may silently drop SYNs under load: re-check the ports
                    // that matter most with low parallelism and a longer timeout.
                    let found = Set(result)
                    let common = Set(PortPreset.commonPorts)
                    let retry = targets.filter { common.contains($0.port) && !found.contains($0) }
                    if targets.count > 64, !retry.isEmpty, !cancelled.isCancelled {
                        let slow = Options(concurrency: 48, timeout: options.timeout * 2)
                        result += run(retry, options: slow, cancelled: cancelled, onOpen: onOpen, onProgress: nil)
                        result.sort { a, b in a.ip != b.ip ? a.ip < b.ip : a.port < b.port }
                    }
                    continuation.resume(returning: result)
                }
                thread.name = "landetector.portscan"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    final class CancelFlag: Sendable {
        private let flag = Atomic<Bool>(false)
        var isCancelled: Bool { flag.load(ordering: .relaxed) }
        func cancel() { flag.store(true, ordering: .relaxed) }
    }

    private static func run(_ targets: [PortTarget], options: Options, cancelled: CancelFlag,
                            onOpen: @Sendable (PortTarget) -> Void,
                            onProgress: (@Sendable (Int, Int) -> Void)?) -> [PortTarget] {
        raiseFileLimit()
        let kq = kqueue()
        guard kq >= 0 else { return [] }
        defer { Darwin.close(kq) }

        struct Pending { let target: PortTarget; let deadline: UInt64 }
        var pending: [Int32: Pending] = [:]
        var open: [PortTarget] = []
        var next = 0
        var done = 0
        var lastProgress = 0
        let timeoutNanos = UInt64(options.timeout.components.seconds) * 1_000_000_000
            + UInt64(options.timeout.components.attoseconds / 1_000_000_000)
        let eventCapacity = 256
        let events = UnsafeMutablePointer<kevent>.allocate(capacity: eventCapacity)
        defer { events.deallocate() }

        func finish(_ fd: Int32, isOpen: Bool) {
            guard let p = pending.removeValue(forKey: fd) else { return }
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
            Darwin.close(fd)
            done += 1
            if isOpen {
                open.append(p.target)
                onOpen(p.target)
            }
        }

        while (next < targets.count || !pending.isEmpty) && !cancelled.isCancelled {
            // Fill the window.
            while pending.count < options.concurrency && next < targets.count {
                let target = targets[next]
                next += 1
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else {
                    next -= 1
                    break // out of descriptors – wait for some to complete
                }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var sa = target.ip.sockaddr(port: target.port)
                let r = withUnsafePointer(to: &sa) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
                pending[fd] = Pending(target: target, deadline: deadline)
                if r == 0 {
                    finish(fd, isOpen: true)
                } else if errno == EINPROGRESS {
                    var ev = kevent(ident: UInt(fd), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_ONESHOT),
                                    fflags: 0, data: 0, udata: nil)
                    kevent(kq, &ev, 1, nil, 0, nil)
                } else {
                    finish(fd, isOpen: false)
                }
            }

            var timeout = timespec(tv_sec: 0, tv_nsec: 20_000_000)
            let n = kevent(kq, nil, 0, events, Int32(eventCapacity), &timeout)
            if n > 0 {
                for i in 0..<Int(n) {
                    let fd = Int32(events[i].ident)
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    let eof = events[i].flags & UInt16(EV_EOF) != 0
                    finish(fd, isOpen: error == 0 && !(eof && events[i].fflags != 0))
                }
            }

            let now = DispatchTime.now().uptimeNanoseconds
            for (fd, p) in pending where p.deadline <= now { finish(fd, isOpen: false) }

            if let onProgress, done - lastProgress >= 64 || (next >= targets.count && pending.isEmpty) {
                lastProgress = done
                onProgress(done, targets.count)
            }
        }
        for fd in pending.keys { Darwin.close(fd) }
        return open.sorted { a, b in a.ip != b.ip ? a.ip < b.ip : a.port < b.port }
    }

    private static let raised = Mutex(false)

    /// GUI apps start with a soft limit of 256 descriptors.
    private static func raiseFileLimit() {
        raised.withLock { done in
            guard !done else { return }
            done = true
            var limit = rlimit()
            guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
            let wanted = min(rlim_t(8192), limit.rlim_max)
            if limit.rlim_cur < wanted {
                limit.rlim_cur = wanted
                setrlimit(RLIMIT_NOFILE, &limit)
            }
        }
    }

    /// Parses `22,80,443,8000-8100`.
    public static func parsePorts(_ text: String) -> [UInt16] {
        var ports = Set<UInt16>()
        for part in text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" || $0.isNewline }) {
            let bounds = part.split(separator: "-", maxSplits: 1)
            if bounds.count == 2, let a = UInt16(bounds[0]), let b = UInt16(bounds[1]), a > 0 {
                for p in min(a, b)...max(a, b) { ports.insert(p) }
            } else if let p = UInt16(part), p > 0 {
                ports.insert(p)
            }
        }
        return ports.sorted()
    }
}

public enum WakeOnLAN {
    /// Sends a magic packet to the subnet broadcast and 255.255.255.255 on ports 7 and 9.
    public static func wake(_ mac: MACAddress, broadcast: IPv4Address?) throws {
        let socket = try DatagramSocket(family: AF_INET, protocol: IPPROTO_UDP, label: "wol")
        defer { socket.close() }
        socket.enableBroadcast()
        let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: mac.bytes, count: 16).joined())
        var targets = [IPv4Address(255, 255, 255, 255)]
        if let broadcast { targets.append(broadcast) }
        for target in targets {
            for port: UInt16 in [9, 7] { socket.send(packet, to: target, port: port) }
        }
    }
}

public enum PublicIPService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    private struct IPReply: Decodable { let ip: String }

    private struct WhoIs: Decodable {
        struct Connection: Decodable { let isp: String?; let org: String? }
        let success: Bool?
        let country: String?
        let country_code: String?
        let city: String?
        let connection: Connection?
    }

    private struct IPInfo: Decodable {
        let ip: String?
        let city: String?
        let country: String?
        let org: String?
    }

    public static func fetch() async -> PublicIPInfo {
        async let v4 = ip(from: "https://api4.ipify.org?format=json")
        async let v6 = ip(from: "https://api6.ipify.org?format=json")
        var info = PublicIPInfo()
        info.ipv4 = await v4
        info.ipv6 = await v6
        if let address = info.ipv4 ?? info.ipv6 {
            if let url = URL(string: "https://ipwho.is/\(address)"),
               let (data, _) = try? await session.data(from: url),
               let who = try? JSONDecoder().decode(WhoIs.self, from: data), who.success != false {
                info.country = who.country
                info.countryCode = who.country_code
                info.city = who.city
                info.isp = who.connection?.isp ?? who.connection?.org
            } else if let url = URL(string: "https://ipinfo.io/\(address)/json"),
                      let (data, _) = try? await session.data(from: url),
                      let ipinfo = try? JSONDecoder().decode(IPInfo.self, from: data) {
                info.countryCode = ipinfo.country
                info.country = ipinfo.country.flatMap { Locale.current.localizedString(forRegionCode: $0) }
                info.city = ipinfo.city
                info.isp = ipinfo.org.map { org in
                    // "AS4134 CHINANET-BACKBONE" → "CHINANET-BACKBONE"
                    org.hasPrefix("AS") ? org.split(separator: " ", maxSplits: 1).dropFirst().joined() : org
                }
            }
        }
        if info.country == nil, let code = info.countryCode {
            info.country = Locale.current.localizedString(forRegionCode: code)
        }
        return info
    }

    private static func ip(from string: String) async -> String? {
        guard let url = URL(string: string), let (data, _) = try? await session.data(from: url),
              let reply = try? JSONDecoder().decode(IPReply.self, from: data) else { return nil }
        return reply.ip
    }
}
