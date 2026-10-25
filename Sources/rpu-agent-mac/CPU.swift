import Darwin
import Foundation
import IOKit
import RPUProtocol

/// Core groups ("Super"/"Performance" on M5, "Performance"/"Efficiency" on M1–M4)
/// mapped onto logical CPU indices.
struct CPUTopology {
    struct Cluster {
        var name: String
        /// 0 = highest performance level (hw.perflevel0).
        var perfLevel: Int
        var cpus: [Int]
        /// Device-tree cluster-type letter ("E"/"P" on M1–M4, "M"/"P" on M5); it is
        /// also the first letter of the matching IOReport complexes (ECPU, MCPU0, PCPU…).
        var letter: String?
    }

    var clusters: [Cluster]
    var logicalCPUs: Int
    /// How the core→cluster mapping was derived (for --dump-topology).
    var source: String

    static func detect() -> CPUTopology {
        let logical = Int(Sysctl.int("hw.logicalcpu") ?? 0)
        let levels = Int(Sysctl.int("hw.nperflevels") ?? 0)
        var named: [(name: String, count: Int)] = []
        for i in 0..<max(levels, 0) {
            let name = Sysctl.string("hw.perflevel\(i).name") ?? "Level \(i)"
            let count = Int(Sysctl.int("hw.perflevel\(i).logicalcpu") ?? 0)
            named.append((name, count))
        }
        guard !named.isEmpty, named.reduce(0, { $0 + $1.count }) == logical else {
            return CPUTopology(clusters: [Cluster(name: "CPU", perfLevel: 0, cpus: Array(0..<max(logical, 1)))],
                               logicalCPUs: logical, source: "single")
        }

        // Preferred: the device tree gives each CPU's cluster-type letter. Map letters
        // to perf levels by matching core counts (unambiguous when the counts differ).
        let dt = deviceTreeClusterTypes()
        var byLetter: [String: [Int]] = [:]
        for (cpu, letter) in dt { byLetter[letter, default: []].append(cpu) }
        if dt.count == logical {
            let counts = named.map(\.count)
            if byLetter.count == named.count, Set(counts).count == counts.count {
                var clusters: [Cluster] = []
                for (letter, cpus) in byLetter {
                    guard let level = counts.firstIndex(of: cpus.count) else { clusters = []; break }
                    clusters.append(Cluster(name: named[level].name, perfLevel: level, cpus: cpus.sorted(), letter: letter))
                }
                if clusters.count == named.count {
                    clusters.sort { ($0.cpus.first ?? 0) < ($1.cpus.first ?? 0) }
                    return CPUTopology(clusters: clusters, logicalCPUs: logical, source: "devicetree")
                }
            }
        }

        // Fallback: Apple numbers logical CPUs starting from the lowest perf level
        // (E-cores are cpu0… on M1–M4, M-cores on M5).
        var clusters: [Cluster] = []
        var start = 0
        for level in stride(from: named.count - 1, through: 0, by: -1) {
            let n = named[level].count
            let cpus = Array(start..<start + n)
            let letters = Set(cpus.compactMap { dt[$0] })
            clusters.append(Cluster(name: named[level].name, perfLevel: level, cpus: cpus,
                                    letter: letters.count == 1 ? letters.first : nil))
            start += n
        }
        return CPUTopology(clusters: clusters, logicalCPUs: logical, source: "perflevel-order")
    }

    /// Logical CPU index → cluster-type ("E"/"P"/"M"…) from IODeviceTree:/cpus. Uses
    /// `logical-cpu-id` when present, else the node name ("cpu12" → 12).
    static func deviceTreeClusterTypes() -> [Int: String] {
        var result: [Int: String] = [:]
        for entry in IORegistry.children(of: "IODeviceTree:/cpus") {
            defer { IOObjectRelease(entry) }
            guard let type = IORegistry.string(fromData: IORegistry.property(entry, "cluster-type")),
                  !type.isEmpty else { continue }
            // Node names look like "cpu12" (or "cpu2@100" in ioreg listings).
            let id = IORegistry.uint32(fromData: IORegistry.property(entry, "logical-cpu-id")).map(Int.init)
                ?? Int(IORegistry.name(entry).drop { !$0.isNumber }.prefix { $0.isNumber })
            if let id { result[id] = type }
        }
        return result
    }

    var clusterInfo: [ClusterInfo] { clusters.map { ClusterInfo(name: $0.name, cores: $0.cpus.count, cpus: $0.cpus) } }

    func dump() -> String {
        var lines = ["source: \(source)", "logical CPUs: \(logicalCPUs)"]
        let levels = Int(Sysctl.int("hw.nperflevels") ?? 0)
        for i in 0..<max(levels, 0) {
            lines.append("perflevel\(i): name=\(Sysctl.string("hw.perflevel\(i).name") ?? "?") "
                + "logical=\(Sysctl.int("hw.perflevel\(i).logicalcpu") ?? -1) "
                + "l2=\(Sysctl.int("hw.perflevel\(i).l2cachesize") ?? -1)")
        }
        for entry in IORegistry.children(of: "IODeviceTree:/cpus") {
            let props = IORegistry.properties(entry)
            let id = IORegistry.uint32(fromData: props["logical-cpu-id"]).map(String.init) ?? "?"
            let cl = IORegistry.uint32(fromData: props["cluster-id"]).map(String.init) ?? "?"
            let type = IORegistry.string(fromData: props["cluster-type"]) ?? "?"
            let compat = IORegistry.string(fromData: props["compatible"]) ?? "?"
            lines.append("  \(IORegistry.name(entry)): logical=\(id) cluster-id=\(cl) cluster-type=\(type) compatible=\(compat)")
            IOObjectRelease(entry)
        }
        for c in clusters {
            lines.append("cluster \(c.name) (perflevel\(c.perfLevel), type \(c.letter ?? "?")): cpus \(c.cpus)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Per-core utilisation from Mach processor load ticks.
final class CPUSampler {
    private typealias Ticks = (busy: UInt32, total: UInt32)
    private let host = mach_host_self()
    private var previous: [Ticks]?
    let topology: CPUTopology

    init(topology: CPUTopology) {
        self.topology = topology
        previous = readTicks()
    }

    private func readTicks() -> [Ticks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var result: [Ticks] = []
        result.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            let busy = user &+ system &+ nice
            result.append((busy, busy &+ idle))
        }
        return result
    }

    /// Per-core utilisation (0–100) since the previous call.
    func sampleCores() -> [Double?] {
        guard let now = readTicks() else { return [] }
        defer { previous = now }
        guard let prev = previous, prev.count == now.count else { return [] }
        return zip(prev, now).map { a, b -> Double? in
            let total = b.total &- a.total
            guard total > 0 else { return nil }
            let busy = b.busy &- a.busy
            return min(100, max(0, 100 * Double(busy) / Double(total))).rounded(1)
        }
    }

    static func loadAverage() -> [Double]? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return loads.map { $0.rounded(2) }
    }
}
