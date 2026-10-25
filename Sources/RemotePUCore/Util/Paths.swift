import CryptoKit
import Darwin
import Foundation
import RPUIPC

/// Filesystem layout. Everything lives under one data directory so tests can run an
/// isolated instance with `--data-dir /tmp/x` (or RPU_DATA_DIR).
public struct RPUPaths: Sendable {
    public let dataDir: URL
    public let controlMasterDir: String
    public let controlSocket: String
    public let askpassSocket: String

    public var nodesFile: URL { dataDir.appendingPathComponent("nodes.json") }
    public var settingsFile: URL { dataDir.appendingPathComponent("settings.json") }
    public var historyDB: URL { dataDir.appendingPathComponent("history.sqlite") }
    public var logFile: URL { dataDir.appendingPathComponent("remotepu.log") }

    public init(dataDir: URL, cacheDir: URL? = nil) {
        self.dataDir = dataDir
        let cache = cacheDir ?? dataDir
        // Unix socket paths are limited to 103 bytes; ssh also appends a ~17 char
        // temporary suffix while creating ControlPath sockets.
        controlMasterDir = Self.shortEnough(cache.appendingPathComponent("cm").path, reserve: 40, fallback: "cm")
        controlSocket = Self.shortEnough(dataDir.appendingPathComponent("control.sock").path, reserve: 0, fallback: "control.sock")
        askpassSocket = Self.shortEnough(dataDir.appendingPathComponent("askpass.sock").path, reserve: 0, fallback: "askpass.sock")
    }

    /// Standard locations, honouring an explicit override or $RPU_DATA_DIR.
    public static func standard(dataDirOverride: String? = nil) -> RPUPaths {
        let env = ProcessInfo.processInfo.environment
        if let custom = dataDirOverride ?? env["RPU_DATA_DIR"], !custom.isEmpty {
            return RPUPaths(dataDir: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemotePU", isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemotePU", isDirectory: true)
        return RPUPaths(dataDir: support, cacheDir: caches)
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for dir in [controlMasterDir, (controlSocket as NSString).deletingLastPathComponent,
                    (askpassSocket as NSString).deletingLastPathComponent] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// ControlPath socket for a node (short, stable per node id).
    public func controlPath(for nodeID: String) -> String {
        let digest = SHA256.hash(data: Data(nodeID.utf8)).map { String(format: "%02x", $0) }.joined()
        return (controlMasterDir as NSString).appendingPathComponent(String(digest.prefix(12)))
    }

    private static func shortEnough(_ path: String, reserve: Int, fallback: String) -> String {
        if path.utf8.count + reserve <= unixSocketPathLimit { return path }
        let dir = "/tmp/rpu-\(getuid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return (dir as NSString).appendingPathComponent(fallback)
    }
}

/// Finds bundled helper executables (rpu-agent-mac, rpu-askpass).
public enum HelperLocator {
    public static func find(_ name: String) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let dir = ProcessInfo.processInfo.environment["RPU_HELPERS_DIR"] {
            candidates.append((dir as NSString).appendingPathComponent(name))
        }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            candidates.append(bundle.appendingPathComponent("Contents/Helpers/\(name)").path)
            candidates.append(bundle.appendingPathComponent("Contents/MacOS/\(name)").path)
        }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent(name).path)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// The bundle keeps the gzip in Contents/Resources (Helpers may only hold code).
    public static func findAgentGzip(agentPath: String) -> String? {
        let fm = FileManager.default
        let helpers = (agentPath as NSString).deletingLastPathComponent
        var candidates = [agentPath + ".gz",
                          ((helpers as NSString).deletingLastPathComponent as NSString)
                              .appendingPathComponent("Resources/rpu-agent-mac.gz")]
        if let res = Bundle.main.resourceURL { candidates.insert(res.appendingPathComponent("rpu-agent-mac.gz").path, at: 0) }
        return candidates.first { fm.fileExists(atPath: $0) }
    }
}

public enum Hashing {
    public static func sha256Hex(fileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func randomToken(bytes: Int = 24) -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }
}

public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
