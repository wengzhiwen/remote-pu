import Foundation
import RPUProtocol

/// Node-level metrics that are charted and persisted. Raw values are SQL column names.
public enum NodeMetric: String, CaseIterable, Codable, Sendable {
    case cpuUtil = "cpu_util"
    case cpuTemp = "cpu_temp"
    case cpuFreq = "cpu_freq"
    case cpuPower = "cpu_power"
    case memUsed = "mem_used"
    case memTotal = "mem_total"
    case swapUsed = "swap_used"
    case load1 = "load1"
    case sysPower = "sys_power"
    case socGPUPower = "soc_gpu_power"
    case anePower = "ane_power"
    case fanRPM = "fan_rpm"

    public func value(_ s: SampleMessage) -> Double? {
        switch self {
        case .cpuUtil: return s.cpu?.util
        case .cpuTemp: return s.cpu?.tempC
        case .cpuFreq: return s.cpu?.freqMhz
        case .cpuPower: return s.cpu?.powerW ?? s.power?.cpuW
        case .memUsed: return s.mem?.used
        case .memTotal: return s.mem?.total
        case .swapUsed: return s.mem?.swapUsed
        case .load1: return s.cpu?.load?.first
        case .sysPower: return s.power?.systemW
        case .socGPUPower: return s.power?.gpuW
        case .anePower: return s.power?.aneW
        case .fanRPM:
            let rpms = (s.fans ?? []).compactMap(\.rpm)
            return rpms.isEmpty ? nil : rpms.reduce(0, +) / Double(rpms.count)
        }
    }
}

public enum GPUMetric: String, CaseIterable, Codable, Sendable {
    case util
    case memUtil = "mem_util"
    case memUsed = "mem_used"
    case memTotal = "mem_total"
    case temp
    case power
    case smMhz = "sm_mhz"
    case memMhz = "mem_mhz"
    case fanPct = "fan_pct"

    public func value(_ g: GPUSample) -> Double? {
        switch self {
        case .util: return g.util
        case .memUtil: return g.memUtil
        case .memUsed: return g.memUsed
        case .memTotal: return g.memTotal
        case .temp: return g.tempC
        case .power: return g.powerW
        case .smMhz: return g.smMhz
        case .memMhz: return g.memMhz
        case .fanPct: return g.fanPct
        }
    }
}

/// A chartable series: a node metric, or a metric of one GPU (by stable key).
public enum MetricRef: Hashable, Sendable, CustomStringConvertible {
    case node(NodeMetric)
    case gpu(key: String, GPUMetric)

    /// "cpu_util" or "gpu:<key>:util".
    public var description: String {
        switch self {
        case .node(let m): return m.rawValue
        case .gpu(let key, let m): return "gpu:\(key):\(m.rawValue)"
        }
    }

    public init?(string: String) {
        if string.hasPrefix("gpu:") {
            let parts = string.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 3, let m = GPUMetric(rawValue: String(parts.last!)) else { return nil }
            self = .gpu(key: parts[1..<(parts.count - 1)].joined(separator: ":"), m)
        } else if let m = NodeMetric(rawValue: string) {
            self = .node(m)
        } else {
            return nil
        }
    }

    /// Extract the value from a sample; `gpuKeys` maps GPU idx → stable key (from hello).
    public func value(in sample: SampleMessage, gpuKeys: [Int: String]) -> Double? {
        switch self {
        case .node(let m):
            return m.value(sample)
        case .gpu(let key, let m):
            guard let g = sample.gpus?.first(where: { (gpuKeys[$0.idx] ?? "idx\($0.idx)") == key }) else { return nil }
            return m.value(g)
        }
    }
}

public struct SeriesPoint: Sendable, Equatable, Codable {
    public var t: Date
    public var avg: Double
    public var max: Double

    public init(t: Date, avg: Double, max: Double) {
        self.t = t
        self.avg = avg
        self.max = max
    }
}

public extension HelloMessage {
    /// GPU idx → stable key (uuid when available).
    var gpuKeys: [Int: String] {
        var m: [Int: String] = [:]
        for g in gpus ?? [] { m[g.idx] = g.key }
        return m
    }
}

/// Fixed-capacity FIFO used for the 1 s in-memory history.
public struct RingBuffer<Element> {
    public let capacity: Int
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: nil, count: self.capacity)
    }

    public mutating func append(_ e: Element) {
        storage[(head + count) % capacity] = e
        if count < capacity {
            count += 1
        } else {
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    /// Oldest → newest.
    public var elements: [Element] {
        (0..<count).compactMap { storage[(head + $0) % capacity] }
    }

    public var last: Element? { count == 0 ? nil : storage[(head + count - 1) % capacity] }
}
