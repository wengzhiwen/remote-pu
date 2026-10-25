import Foundation

/// Tiny thread-safe logger: keeps the last lines in memory (served by the control API's
/// `log.tail`) and appends to a file when configured.
public final class RPULog: @unchecked Sendable {
    public static let shared = RPULog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 2000
    private var file: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    public var echoToStderr = false

    public init() {}

    public func configure(fileURL: URL?) {
        lock.lock()
        defer { lock.unlock() }
        try? file?.close()
        file = nil
        guard let url = fileURL else { return }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int, size > 5 << 20 {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
    }

    public func log(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        if let file { try? file.write(contentsOf: Data((line + "\n").utf8)) }
        lock.unlock()
        if echoToStderr { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }

    public func tail(_ n: Int, matching filter: String? = nil) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let source = filter.map { f in lines.filter { $0.contains(f) } } ?? lines
        return Array(source.suffix(max(0, n)))
    }
}
