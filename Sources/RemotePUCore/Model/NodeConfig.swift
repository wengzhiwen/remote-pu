import Foundation

public enum NodeKind: String, Codable, Sendable, CaseIterable {
    /// This Mac, sampled by a locally spawned rpu-agent-mac.
    case local
    /// Remote Linux or Mac over the system ssh.
    case ssh
    /// Synthetic data for UI development/tests.
    case demo
}

public enum SSHAuthMode: String, Codable, Sendable, CaseIterable {
    /// Keys / ssh-agent / ~/.ssh/config only; never prompts (BatchMode=yes).
    case system
    /// Password (or keyboard-interactive) answered from the Keychain via SSH_ASKPASS.
    case password
}

public struct NodeConfig: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var kind: NodeKind
    /// ssh destination: a ~/.ssh/config alias or user@host.
    public var target: String
    public var port: Int?
    public var identityFile: String?
    public var auth: SSHAuthMode
    /// Seconds between samples.
    public var interval: Double
    public var enabled: Bool
    /// Extra `-o Key=Value` options, e.g. "ProxyJump=bastion".
    public var sshOptions: [String]
    /// Demo profile ("linux-2gpu" | "mac") for kind == .demo.
    public var demoProfile: String?
    /// SF Symbol shown next to the node everywhere (nil = automatic from the platform).
    public var icon: String?
    /// Whether the node appears in the menu bar title ("nodes" mode).
    public var showInMenuBar: Bool
    /// Menu bar value: "auto" (GPU for GPU servers, else CPU) | "cpu" | "gpu" | "temp".
    public var menuMetric: String

    public init(id: String? = nil, name: String, kind: NodeKind = .ssh, target: String = "", port: Int? = nil,
                identityFile: String? = nil, auth: SSHAuthMode = .system, interval: Double = 1,
                enabled: Bool = true, sshOptions: [String] = [], demoProfile: String? = nil,
                icon: String? = nil, showInMenuBar: Bool = true, menuMetric: String = "auto") {
        self.id = id ?? NodeConfig.makeID(from: name)
        self.name = name
        self.kind = kind
        self.target = target
        self.port = port
        self.identityFile = identityFile
        self.auth = auth
        self.interval = interval
        self.enabled = enabled
        self.sshOptions = sshOptions
        self.demoProfile = demoProfile
        self.icon = icon
        self.showInMenuBar = showInMenuBar
        self.menuMetric = menuMetric
    }

    public static let localID = "local"

    public static func local() -> NodeConfig {
        NodeConfig(id: localID, name: String(localized: "This Mac"), kind: .local)
    }

    /// A readable, filesystem-safe id derived from a name ("GPU box #1" → "gpu-box-1").
    public static func makeID(from name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        var out = ""
        for ch in name.lowercased() {
            if allowed.contains(ch) { out.append(ch) } else if out.last != "-" { out.append("-") }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "node-\(UUID().uuidString.prefix(8).lowercased())" : out
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, target, port, identityFile, auth, interval, enabled, sshOptions, demoProfile
        case icon, showInMenuBar, menuMetric
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? NodeConfig.makeID(from: name)
        kind = try c.decodeIfPresent(NodeKind.self, forKey: .kind) ?? .ssh
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        auth = try c.decodeIfPresent(SSHAuthMode.self, forKey: .auth) ?? .system
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sshOptions = try c.decodeIfPresent([String].self, forKey: .sshOptions) ?? []
        demoProfile = try c.decodeIfPresent(String.self, forKey: .demoProfile)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        menuMetric = try c.decodeIfPresent(String.self, forKey: .menuMetric) ?? "auto"
    }
}

public enum NodePhase: String, Codable, Sendable, CaseIterable {
    case idle, connecting, probing, deploying, starting, online, stale, offline, authFailed, disabled

    public var isConnecting: Bool { [.connecting, .probing, .deploying, .starting].contains(self) }
}

public struct NodeStatus: Codable, Sendable, Equatable {
    public var phase: NodePhase
    public var message: String?
    public var since: Date
    public var retryAt: Date?

    public init(phase: NodePhase, message: String? = nil, since: Date = Date(), retryAt: Date? = nil) {
        self.phase = phase
        self.message = message
        self.since = since
        self.retryAt = retryAt
    }
}

/// User preferences persisted in settings.json.
public struct AppSettings: Codable, Sendable, Equatable {
    /// What the menu bar title shows: "nodes" (icon + value per node) | "maxGPU" |
    /// "maxCPU" (busiest node's icon + value) | "icon".
    public var menuBarMode: String = "nodes"
    public var menuBarNodeID: String?
    public var defaultInterval: Double = 1
    public var retention5sDays: Double = 7
    public var retention1mDays: Double = 90
    public var showLocalNode: Bool = true
    public var openDashboardAtLaunch: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case menuBarMode, menuBarNodeID, defaultInterval, retention5sDays, retention1mDays, showLocalNode,
             openDashboardAtLaunch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        menuBarMode = try c.decodeIfPresent(String.self, forKey: .menuBarMode) ?? d.menuBarMode
        menuBarNodeID = try c.decodeIfPresent(String.self, forKey: .menuBarNodeID)
        defaultInterval = try c.decodeIfPresent(Double.self, forKey: .defaultInterval) ?? d.defaultInterval
        retention5sDays = try c.decodeIfPresent(Double.self, forKey: .retention5sDays) ?? d.retention5sDays
        retention1mDays = try c.decodeIfPresent(Double.self, forKey: .retention1mDays) ?? d.retention1mDays
        showLocalNode = try c.decodeIfPresent(Bool.self, forKey: .showLocalNode) ?? d.showLocalNode
        openDashboardAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .openDashboardAtLaunch) ?? d.openDashboardAtLaunch
    }
}

/// Loads/saves nodes.json and settings.json (pretty, atomic).
public struct ConfigStore: Sendable {
    public let paths: RPUPaths

    public init(paths: RPUPaths) { self.paths = paths }

    public func loadNodes() -> [NodeConfig] {
        guard let data = try? Data(contentsOf: paths.nodesFile),
              let nodes = try? JSONDecoder().decode([NodeConfig].self, from: data) else {
            return [NodeConfig.local()]
        }
        return nodes
    }

    public func saveNodes(_ nodes: [NodeConfig]) throws {
        try write(nodes, to: paths.nodesFile)
    }

    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try write(settings, to: paths.settingsFile)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(value).write(to: url, options: .atomic)
    }
}
