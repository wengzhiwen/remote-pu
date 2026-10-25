import Darwin
import Foundation

public enum UnixSocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case sys(String, Int32)
    case closed
    case timeout

    public var description: String {
        switch self {
        case .pathTooLong(let p): return "unix socket path too long (\(p.utf8.count) bytes): \(p)"
        case .sys(let what, let err): return "\(what): \(String(cString: strerror(err)))"
        case .closed: return "connection closed"
        case .timeout: return "timed out"
        }
    }
}

/// Fills a sockaddr_un for `path`.
func makeUnixAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { throw UnixSocketError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        raw.copyBytes(from: bytes)
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

/// Longest path that fits in sockaddr_un.sun_path (minus the NUL).
public let unixSocketPathLimit: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

/// Blocking line I/O helpers over a connected socket fd.
public enum LineIO {
    public static func writeLine(_ fd: Int32, _ line: String) throws {
        var data = Array(line.utf8)
        if data.last != 0x0A { data.append(0x0A) }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.sys("write", errno)
            }
            offset += n
        }
    }

    /// Reads up to the first newline (excluded). Returns nil on EOF before any byte.
    public static func readLine(_ fd: Int32, limit: Int = 8 << 20) throws -> String? {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n == 0 { return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw UnixSocketError.timeout }
                throw UnixSocketError.sys("read", errno)
            }
            if byte == 0x0A { return String(decoding: buffer, as: UTF8.self) }
            buffer.append(byte)
            if buffer.count > limit { throw UnixSocketError.sys("read (line too long)", EMSGSIZE) }
        }
    }

    static func setTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// One-request-per-connection client: connect, send a line, read a line.
public enum UnixSocketClient {
    public static func request(path: String, line: String, timeout: Double = 30) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.sys("socket", errno) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = try makeUnixAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw UnixSocketError.sys("connect \(path)", errno) }
        LineIO.setTimeout(fd, seconds: timeout)
        try LineIO.writeLine(fd, line)
        guard let reply = try LineIO.readLine(fd) else { throw UnixSocketError.closed }
        return reply
    }
}

/// Minimal Unix-domain-socket server. Each connection carries exactly one request
/// line and one response line. The socket file is created with mode 0600.
public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (String) async -> String

    public let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "rpu.unixsocket.accept")

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.sys("socket", errno) }
        var addr = try makeUnixAddress(path)
        let oldMask = umask(0o077)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw UnixSocketError.sys("bind \(path)", e)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            throw UnixSocketError.sys("listen", e)
        }
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    public func stop() {
        if let s = source {
            s.cancel()
            source = nil
            unlink(path)
        }
        listenFD = -1
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        LineIO.setTimeout(client, seconds: 30)
        let handler = self.handler
        DispatchQueue.global(qos: .userInitiated).async {
            guard let line = try? LineIO.readLine(client) else {
                close(client)
                return
            }
            Task.detached {
                let reply = await handler(line)
                DispatchQueue.global(qos: .userInitiated).async {
                    try? LineIO.writeLine(client, reply)
                    close(client)
                }
            }
        }
    }
}
