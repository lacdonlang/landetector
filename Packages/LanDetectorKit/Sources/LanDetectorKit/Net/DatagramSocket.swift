import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case create(Int32)
    case bind(Int32)
    case option(Int32)

    public var description: String {
        switch self {
        case .create(let e): "socket() failed: \(String(cString: strerror(e)))"
        case .bind(let e): "bind() failed: \(String(cString: strerror(e)))"
        case .option(let e): "setsockopt() failed: \(String(cString: strerror(e)))"
        }
    }
}

/// Sender address of a received datagram.
public enum SocketAddress: Hashable, Sendable {
    case v4(IPv4Address, port: UInt16)
    case v6(IPv6Address, port: UInt16, scope: UInt32)

    init?(_ storage: sockaddr_storage) {
        var s = storage
        switch Int32(s.ss_family) {
        case AF_INET:
            let sin = withUnsafeBytes(of: &s) { $0.loadUnaligned(as: sockaddr_in.self) }
            self = .v4(IPv4Address(sin.sin_addr), port: UInt16(bigEndian: sin.sin_port))
        case AF_INET6:
            let sin6 = withUnsafeBytes(of: &s) { $0.loadUnaligned(as: sockaddr_in6.self) }
            self = .v6(IPv6Address(sin6.sin6_addr).withoutEmbeddedScope, port: UInt16(bigEndian: sin6.sin6_port),
                       scope: sin6.sin6_scope_id)
        default:
            return nil
        }
    }

    public var ipv4: IPv4Address? {
        if case .v4(let ip, _) = self { return ip }
        return nil
    }
}

/// A non-blocking datagram socket whose reads are delivered on a private serial queue.
///
/// All callbacks run on `queue`, so state touched only from callbacks or `queue.async`
/// blocks needs no further locking.
public final class DatagramSocket: @unchecked Sendable {
    public let fd: Int32
    public let family: Int32
    public let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var closed = false

    public init(family: Int32 = AF_INET, protocol proto: Int32 = IPPROTO_UDP, label: String) throws {
        self.family = family
        queue = DispatchQueue(label: "landetector.socket.\(label)", qos: .userInitiated)
        fd = socket(family, SOCK_DGRAM, proto)
        guard fd >= 0 else { throw SocketError.create(errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var size: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    // MARK: Options

    @discardableResult
    public func setOption<T: BitwiseCopyable>(_ level: Int32, _ name: Int32, _ value: T) -> Bool {
        var v = value
        return setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<T>.size)) == 0
    }

    public func enableBroadcast() { setOption(SOL_SOCKET, SO_BROADCAST, Int32(1)) }

    /// Routes IPv4 multicast through the interface owning `address`.
    public func setMulticastInterface(_ address: IPv4Address, ttl: UInt8 = 255) {
        setOption(IPPROTO_IP, IP_MULTICAST_IF, address.inAddr)
        setOption(IPPROTO_IP, IP_MULTICAST_TTL, ttl)
        setOption(IPPROTO_IP, IP_MULTICAST_LOOP, UInt8(0))
    }

    /// Binds the socket to a specific interface (IP_BOUND_IF / IPV6_BOUND_IF).
    public func bindToInterface(index: UInt32) {
        if family == AF_INET6 {
            setOption(IPPROTO_IPV6, IPV6_BOUND_IF, Int32(index))
        } else {
            setOption(IPPROTO_IP, IP_BOUND_IF, Int32(index))
        }
    }

    public func bind(port: UInt16, address: IPv4Address = IPv4Address(0)) throws {
        var sa = address.sockaddr(port: port)
        let r = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 { throw SocketError.bind(errno) }
    }

    public func bind6(address: IPv6Address, scope: UInt32 = 0) throws {
        var sa = sockaddr_in6()
        sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sa.sin6_family = sa_family_t(AF_INET6)
        sa.sin6_addr = address.in6Addr
        sa.sin6_scope_id = scope
        let r = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if r != 0 { throw SocketError.bind(errno) }
    }

    // MARK: Sending

    @discardableResult
    public func send(_ bytes: [UInt8], to ip: IPv4Address, port: UInt16) -> Int32 {
        var sa = ip.sockaddr(port: port)
        return sendRaw(bytes, &sa, MemoryLayout<sockaddr_in>.size)
    }

    @discardableResult
    public func send(_ bytes: [UInt8], to ip: IPv6Address, port: UInt16 = 0, scope: UInt32) -> Int32 {
        var sa = sockaddr_in6()
        sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sa.sin6_family = sa_family_t(AF_INET6)
        sa.sin6_port = port.bigEndian
        sa.sin6_addr = ip.in6Addr
        sa.sin6_scope_id = scope
        return sendRaw(bytes, &sa, MemoryLayout<sockaddr_in6>.size)
    }

    /// Returns 0 on success or the errno value.
    private func sendRaw<T>(_ bytes: [UInt8], _ sa: inout T, _ length: Int) -> Int32 {
        for attempt in 0..<3 {
            let r = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(length))
                }
            }
            if r >= 0 { return 0 }
            let err = errno
            // The kernel queue is momentarily full during fast sweeps – back off briefly.
            guard err == ENOBUFS || err == EAGAIN, attempt < 2 else { return err }
            usleep(2000)
        }
        return ENOBUFS
    }

    // MARK: Receiving

    public func startReceiving(_ handler: @escaping @Sendable (_ data: [UInt8], _ from: SocketAddress) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 9000)
            while true {
                var storage = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                    }
                }
                guard n > 0 else { break }
                if let from = SocketAddress(storage) {
                    handler(Array(buffer[0..<n]), from)
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    public func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            if let source {
                source.cancel()
            } else {
                Darwin.close(fd)
            }
        }
    }
}
