import Foundation

/// Builds argument vectors for the system ssh.
///
/// One explicit, foreground ControlMaster (`ssh -M -N`) per node owns the connection and
/// authentication; probe/deploy/stream commands are multiplexed clients over its socket,
/// so a password is entered (via askpass) at most once per connection.
public struct SSHCommand: Sendable, Equatable {
    public var sshPath = "/usr/bin/ssh"
    public var target: String
    public var port: Int?
    public var identityFile: String?
    public var auth: SSHAuthMode
    public var options: [String]
    public var controlPath: String
    public var connectTimeout = 10

    public init(config: NodeConfig, controlPath: String, sshPath: String = "/usr/bin/ssh") {
        self.sshPath = sshPath
        target = config.target
        port = config.port
        identityFile = config.identityFile
        auth = config.auth
        options = config.sshOptions
        self.controlPath = controlPath
    }

    var commonOptions: [String] {
        var o = [
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=ERROR",
        ]
        if let port { o += ["-p", String(port)] }
        if let identityFile, !identityFile.isEmpty {
            o += ["-i", (identityFile as NSString).expandingTildeInPath]
        }
        for opt in options where !opt.trimmingCharacters(in: .whitespaces).isEmpty {
            o += ["-o", opt]
        }
        return o
    }

    var authOptions: [String] {
        switch auth {
        case .system:
            return ["-o", "BatchMode=yes"]
        case .password:
            return ["-o", "BatchMode=no",
                    "-o", "NumberOfPasswordPrompts=1",
                    "-o", "PreferredAuthentications=publickey,keyboard-interactive,password"]
        }
    }

    /// The master runs `cat` remotely on a stdin pipe the app holds open: when the app
    /// exits — even by crashing — the pipe hits EOF and the master goes away with it
    /// (`-N` masters would be re-parented to launchd and linger).
    public func masterArguments() -> [String] {
        ["-M", "-T", "-S", controlPath, "-o", "ControlPersist=no"] + commonOptions + authOptions
            + [target, Self.masterRemoteCommand]
    }

    public static let masterRemoteCommand = "exec cat >/dev/null"

    public func clientArguments(_ remoteCommand: String) -> [String] {
        ["-T", "-S", controlPath, "-o", "ControlMaster=no", "-o", "BatchMode=yes"] + commonOptions + [target, remoteCommand]
    }

    public func controlArguments(_ operation: String) -> [String] {
        ["-S", controlPath, "-O", operation, target]
    }
}

/// Remote shell snippets. Each is wrapped in `sh -c '…'` so it behaves the same under
/// bash, zsh or fish login shells.
public enum RemoteScripts {
    public static func sh(_ script: String) -> String { "sh -c " + shellQuote(script) }

    /// Lines: OS (uname -s), arch, python3 path or "-", macOS version or "-".
    public static let probe = sh(
        "uname -s; uname -m; command -v python3 2>/dev/null || echo -; sw_vers -productVersion 2>/dev/null || echo -"
    )

    public static func linuxCollector(python: String, interval: Double) -> String {
        sh("exec \(shellQuote(python)) -u - --interval \(interval)")
    }

    public static func agentDir(hash: String) -> String { "$HOME/.cache/remotepu/agents/\(hash)" }

    /// Prints the agent version when the installed binary exists with the expected
    /// SHA-256 and runs; otherwise prints "missing".
    public static func agentCheck(hash: String, sha256: String) -> String {
        sh("""
        f="\(agentDir(hash: hash))/rpu-agent-mac"; \
        if [ -x "$f" ] && [ "$(shasum -a 256 "$f" | cut -c1-64)" = "\(sha256)" ]; then "$f" --version || echo broken; \
        else echo missing; fi
        """)
    }

    /// Reads the binary (gzip-compressed when `gzipped`) from stdin, verifies its SHA-256,
    /// installs it atomically and prunes stale versions. A truncated transfer (e.g. the
    /// connection dropped mid-upload) fails the checksum and is never installed.
    public static func agentUpload(hash: String, sha256: String, gzipped: Bool) -> String {
        let receive = gzipped ? "gunzip -c > \"$t\"" : "cat > \"$t\""
        return sh("""
        set -e; d="\(agentDir(hash: hash))"; mkdir -p "$d"; t="$d/.upload.$$"; \(receive); \
        if [ "$(shasum -a 256 "$t" | cut -c1-64)" != "\(sha256)" ]; then rm -f "$t"; echo "checksum mismatch" >&2; exit 3; fi; \
        chmod 755 "$t"; mv -f "$t" "$d/rpu-agent-mac"; \
        find "$HOME/.cache/remotepu/agents" -mindepth 1 -maxdepth 1 -type d ! -name \(hash) -mtime +7 -exec rm -rf {} + 2>/dev/null || true; \
        "$d/rpu-agent-mac" --version
        """)
    }

    public static func agentStream(hash: String, interval: Double) -> String {
        sh("exec \"\(agentDir(hash: hash))/rpu-agent-mac\" --interval \(interval)")
    }
}

public struct ProbeResult: Sendable, Equatable {
    public var os: String
    public var arch: String
    public var python: String?
    public var macOSVersion: String?

    public static func parse(_ lines: [String]) -> ProbeResult? {
        let l = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Login banners may precede our output; take the last four lines.
        guard l.count >= 4 else { return nil }
        let tail = Array(l.suffix(4))
        return ProbeResult(os: tail[0], arch: tail[1],
                           python: tail[2] == "-" ? nil : tail[2],
                           macOSVersion: tail[3] == "-" ? nil : tail[3])
    }
}

public enum RunnerError: Error, CustomStringConvertible, Equatable {
    /// Wrong/missing credentials. Not retried automatically (avoids account lockouts).
    case authFailed(String)
    /// Host key mismatch. Not retried automatically.
    case hostKey(String)
    case network(String)
    case unsupported(String)
    case remote(String)
    case timeout(String)
    case configuration(String)

    public var description: String {
        switch self {
        case .authFailed(let m), .hostKey(let m), .network(let m), .unsupported(let m),
             .remote(let m), .timeout(let m), .configuration(let m):
            return m
        }
    }

    /// Errors that need the user to act before retrying.
    public var isTerminal: Bool {
        switch self {
        case .authFailed, .hostKey, .unsupported, .configuration: return true
        default: return false
        }
    }

    /// Classify ssh stderr output.
    public static func classify(sshStderr lines: [String], status: Int32) -> RunnerError {
        let text = lines.joined(separator: "\n")
        let lower = text.lowercased()
        let summary = lines.last(where: { !$0.isEmpty }) ?? "ssh exited with status \(status)"
        if lower.contains("permission denied") || lower.contains("too many authentication failures") {
            return .authFailed(summary)
        }
        if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
            return .hostKey(summary)
        }
        if lower.contains("could not resolve") || lower.contains("connection refused") || lower.contains("timed out")
            || lower.contains("no route to host") || lower.contains("network is unreachable")
            || lower.contains("connection closed") || lower.contains("connection reset") {
            return .network(summary)
        }
        return .remote(summary)
    }
}
