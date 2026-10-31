import Foundation
import RPUProtocol

/// Mode entry from `mgr list --json`: {"mode": "vllm", "name": "vLLM openai server"}.
/// The name is free-form remote text (often Chinese) — display it with
/// `Text(verbatim:)`, never as a localization key.
public struct AetherMode: Codable, Sendable, Equatable, Identifiable {
    public var mode: String
    public var name: String?

    public var id: String { mode }

    public init(mode: String, name: String? = nil) {
        self.mode = mode
        self.name = name
    }
}

/// `mgr status --json` (AetherSwitch ≥ 0.1). Fields the app does not use
/// (systemd properties, gpus, compute_processes) are simply not decoded.
public struct AetherStatus: Codable, Sendable, Equatable {
    public struct ModeReport: Codable, Sendable, Equatable, Identifiable {
        public struct Probe: Codable, Sendable, Equatable {
            public var publicUrl: String?
        }

        public var mode: String
        /// ready | busy | loading | unready | stopping | running | stopped | failed | conflict
        public var state: String?
        public var healthy: Bool?
        public var acceptingRequests: Bool?
        public var busy: Bool?
        public var error: String?
        public var probe: Probe?

        public var id: String { mode }
    }

    /// The exclusive operation record (`mgr` writes it while switch/stop runs).
    public struct Operation: Codable, Sendable, Equatable {
        /// switch | restart | stop | force-stop
        public var action: String?
        public var target: String?
        /// begin | checking | releasing | starting | loading | ready | complete |
        /// stopping | force-stopping | failed | startup-failed
        public var stage: String?
        public var inProgress: Bool?
        public var mode: String?
        public var error: String?
    }

    public var modes: [ModeReport]
    public var operation: Operation?
    public var conflicts: [String]
    /// The single active mode, or nil when stopped / in conflict.
    public var currentMode: String?

    public init(modes: [ModeReport] = [], operation: Operation? = nil, conflicts: [String] = [], currentMode: String? = nil) {
        self.modes = modes
        self.operation = operation
        self.conflicts = conflicts
        self.currentMode = currentMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modes = try c.decodeIfPresent([ModeReport].self, forKey: .modes) ?? []
        operation = try c.decodeIfPresent(Operation.self, forKey: .operation)
        conflicts = try c.decodeIfPresent([String].self, forKey: .conflicts) ?? []
        currentMode = try c.decodeIfPresent(String.self, forKey: .currentMode)
    }

    public func report(for mode: String) -> ModeReport? { modes.first { $0.mode == mode } }
}

public struct AetherError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// An action the UI triggers on a node's AetherSwitch.
public enum AetherAction: Sendable, Equatable {
    case switchTo(String)
    case stop
}

/// Remote command builders for AetherSwitch's `mgr` (GPU mode orchestrator;
/// see the aether-switch project). Every command cds into the configured
/// directory first; `mgr` reports failures as "ERROR: …" on stderr with a
/// non-zero exit.
public enum AetherScripts {
    /// Separates the `mgr list` and `mgr status` JSON documents of one round trip.
    static let splitMarker = "__RPU_AETHER__"

    /// One-shot `mgr status --json` + `mgr list --json` (list is instant, status
    /// probes the running mode). stdout parses with `parse(_:)`.
    public static func statusAndList(dir: String) -> String {
        RemoteScripts.sh("""
        cd \(quotedDir(dir)) || exit 9; \
        echo \(splitMarker); ./mgr list --json; \
        echo \(splitMarker); exec ./mgr status --json
        """)
    }

    public static func switchMode(dir: String, mode: String) -> String {
        RemoteScripts.sh("cd \(quotedDir(dir)) || exit 9; exec ./mgr switch \(shellQuote(mode))")
    }

    public static func restartMode(dir: String, mode: String) -> String {
        RemoteScripts.sh("cd \(quotedDir(dir)) || exit 9; exec ./mgr restart \(shellQuote(mode))")
    }

    public static func stop(dir: String) -> String {
        RemoteScripts.sh("cd \(quotedDir(dir)) || exit 9; exec ./mgr stop")
    }

    /// Splits combined `statusAndList` output into the mode list and the status.
    public static func parse(_ stdout: [String]) throws -> (modes: [AetherMode], status: AetherStatus) {
        let parts = stdout.joined(separator: "\n").components(separatedBy: splitMarker)
        guard parts.count >= 3,
              let listData = parts[1].data(using: .utf8),
              let statusData = parts[2].data(using: .utf8) else {
            throw AetherError("unexpected mgr output")
        }
        let decoder = RPUJSON.makeDecoder()
        let modes = (try? decoder.decode([AetherMode].self, from: listData)) ?? []
        guard let status = try? decoder.decode(AetherStatus.self, from: statusData) else {
            throw AetherError("cannot parse mgr status output")
        }
        return (modes, status)
    }

    /// Double-quoted remote path. A leading "~" becomes an unquoted `$HOME`
    /// prefix (tilde does not expand inside quotes); everything else in the
    /// path is escaped so it is never word-split or expanded.
    static func quotedDir(_ dir: String) -> String {
        let trimmed = dir.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return "\"$HOME\"" }
        var prefix = ""
        var body = trimmed
        if trimmed.hasPrefix("~/") {
            prefix = "\"$HOME\""
            body = String(trimmed.dropFirst()) // keep the leading "/"
        }
        body = body.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return prefix + "\"" + body + "\""
    }
}
