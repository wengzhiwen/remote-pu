import Foundation

/// NDJSON v1 — the only format the app understands. Every collector (Linux python
/// script, rpu-agent-mac, demo generator) writes one of these objects per line.
/// All measurement fields are optional: a missing/null value means "not available".
/// JSON keys are snake_case; use `RPUJSON.encoder/decoder` which convert to camelCase.
public enum RPUProtocolInfo {
    public static let version = 1
}

public enum RPUJSON {
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

// MARK: - hello

public struct HelloMessage: Codable, Sendable, Equatable {
    public var t: String = "hello"
    public var v: Int = RPUProtocolInfo.version
    public var agent: String?
    public var host: String?
    /// "linux" | "macos"
    public var os: String?
    public var osVersion: String?
    public var kernel: String?
    public var arch: String?
    public var wsl: Bool?
    public var model: String?
    public var cpu: CPUInfo?
    public var memTotal: Double?
    public var swapTotal: Double?
    public var gpus: [GPUInfo]?
    public var fans: Int?
    public var caps: Caps?
    public var interval: Double?

    public init() {}
}

public struct CPUInfo: Codable, Sendable, Equatable {
    public var model: String?
    public var cores: Int?
    /// Core groups in logical-CPU order as reported by the OS, e.g. Apple
    /// "Super"/"Performance" (M5) or "Performance"/"Efficiency" (M1), Intel "P-core"/"E-core".
    public var clusters: [ClusterInfo]?

    public init(model: String? = nil, cores: Int? = nil, clusters: [ClusterInfo]? = nil) {
        self.model = model
        self.cores = cores
        self.clusters = clusters
    }
}

public struct ClusterInfo: Codable, Sendable, Equatable {
    public var name: String
    public var cores: Int
    /// Logical CPU indices when not contiguous/in order (Linux collector always sends it).
    public var cpus: [Int]?

    public init(name: String, cores: Int, cpus: [Int]? = nil) {
        self.name = name
        self.cores = cores
        self.cpus = cpus
    }
}

public struct GPUInfo: Codable, Sendable, Equatable {
    public var idx: Int
    public var uuid: String?
    public var name: String?
    public var memTotal: Double?
    public var driver: String?
    public var powerLimitW: Double?
    public var maxSmMhz: Double?
    public var pciBus: String?
    /// GPU core count (Apple GPUs).
    public var cores: Int?
    /// Shares system memory (Apple Silicon, GB10...): VRAM totals are meaningless.
    public var unified: Bool?

    public init(idx: Int) { self.idx = idx }

    /// Stable identity used for history: uuid when the driver reports one.
    public var key: String { uuid ?? "idx\(idx)" }
}

public struct Caps: Codable, Sendable, Equatable {
    public var cpuTemp: Bool?
    public var cpuFreq: Bool?
    public var cpuPower: Bool?
    /// GPU backend name ("nvidia-smi", "ioaccelerator") or nil when no GPU data.
    public var gpu: String?
    public var fans: Bool?
    public var sysPower: Bool?
    public var smc: Bool?
    public var ioreport: Bool?

    public init() {}
}

// MARK: - sample

public struct SampleMessage: Codable, Sendable, Equatable {
    public var t: String = "s"
    /// Unix time, seconds.
    public var ts: Double
    public var seq: Int?
    public var cpu: CPUSample?
    public var mem: MemSample?
    public var gpus: [GPUSample]?
    public var fans: [FanSample]?
    public var power: PowerSample?

    public init(ts: Double) { self.ts = ts }

    public var date: Date { Date(timeIntervalSince1970: ts) }
}

public struct CPUSample: Codable, Sendable, Equatable {
    /// 0–100, whole machine.
    public var util: Double?
    /// Per logical CPU, 0–100.
    public var cores: [Double?]?
    public var clusters: [ClusterSample]?
    public var freqMhz: Double?
    /// Representative CPU temperature (hottest package / mean of die sensors).
    public var tempC: Double?
    public var tempMaxC: Double?
    public var powerW: Double?
    public var load: [Double]?

    public init() {}
}

public struct ClusterSample: Codable, Sendable, Equatable {
    public var name: String
    public var util: Double?
    public var freqMhz: Double?

    public init(name: String, util: Double? = nil, freqMhz: Double? = nil) {
        self.name = name
        self.util = util
        self.freqMhz = freqMhz
    }
}

public struct MemSample: Codable, Sendable, Equatable {
    /// Bytes.
    public var used: Double?
    public var total: Double?
    public var available: Double?
    public var swapUsed: Double?
    public var swapTotal: Double?
    /// macOS memory pressure: "normal" | "warn" | "critical".
    public var pressure: String?

    public init() {}
}

public struct GPUSample: Codable, Sendable, Equatable {
    public var idx: Int
    public var util: Double?
    public var memUtil: Double?
    /// Bytes.
    public var memUsed: Double?
    public var memTotal: Double?
    public var tempC: Double?
    public var memTempC: Double?
    public var powerW: Double?
    public var powerLimitW: Double?
    /// Core clock (NVIDIA SM clock / Apple GPU frequency).
    public var smMhz: Double?
    public var memMhz: Double?
    public var fanPct: Double?
    public var pstate: String?
    /// Active clock-event reasons, e.g. ["sw_power_cap"]; "gpu_idle" is informational.
    public var throttle: [String]?
    public var pcieGen: Int?
    public var pcieWidth: Int?

    public init(idx: Int) { self.idx = idx }
}

public struct FanSample: Codable, Sendable, Equatable {
    public var idx: Int
    public var rpm: Double?
    public var minRpm: Double?
    public var maxRpm: Double?
    public var label: String?

    public init(idx: Int) { self.idx = idx }
}

public struct PowerSample: Codable, Sendable, Equatable {
    /// Watts.
    public var systemW: Double?
    public var cpuW: Double?
    public var gpuW: Double?
    public var aneW: Double?
    public var dramW: Double?

    public init() {}
}

// MARK: - error

public struct ErrorMessage: Codable, Sendable, Equatable {
    public var t: String = "err"
    public var msg: String
    public var fatal: Bool?

    public init(msg: String, fatal: Bool? = nil) {
        self.msg = msg
        self.fatal = fatal
    }
}

// MARK: - decoding

public enum AgentMessage: Sendable, Equatable {
    case hello(HelloMessage)
    case sample(SampleMessage)
    case error(ErrorMessage)
    case unknown(String)

    private struct Envelope: Decodable { let t: String }

    /// Decode one NDJSON line. Returns nil for lines that are not JSON objects
    /// (e.g. a login banner printed by a remote shell rc file).
    public static func decode(line: String, decoder: JSONDecoder = RPUJSON.makeDecoder()) -> AgentMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        do {
            let env = try decoder.decode(Envelope.self, from: data)
            switch env.t {
            case "hello": return .hello(try decoder.decode(HelloMessage.self, from: data))
            case "s": return .sample(try decoder.decode(SampleMessage.self, from: data))
            case "err": return .error(try decoder.decode(ErrorMessage.self, from: data))
            default: return .unknown(env.t)
            }
        } catch {
            return .error(ErrorMessage(msg: "undecodable line: \(error)"))
        }
    }
}
