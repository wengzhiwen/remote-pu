import Darwin
import Foundation
import IOKit
import RPUProtocol

enum MemorySampler {
    private static let host = mach_host_self()

    static var totalBytes: Double? { Sysctl.int("hw.memsize").map(Double.init) }

    static func swap() -> (used: Double, total: Double)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (Double(usage.xsu_used), Double(usage.xsu_total))
    }

    /// "Memory Used" the way Activity Monitor computes it: app + wired + compressed.
    static func sample() -> MemSample {
        var m = MemSample()
        m.total = totalBytes
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count))
            let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
            m.used = used
            if let total = m.total { m.available = max(0, total - used) }
        }
        if let s = swap() {
            m.swapUsed = s.used
            m.swapTotal = s.total
        }
        switch Sysctl.int("kern.memorystatus_vm_pressure_level") {
        case 1: m.pressure = "normal"
        case 2: m.pressure = "warn"
        case 4: m.pressure = "critical"
        default: break
        }
        return m
    }
}

/// Apple GPU utilisation from IOAccelerator's PerformanceStatistics (public registry data).
final class AppleGPUSampler {
    private var service: io_object_t = 0
    let name: String?
    let cores: Int?

    init?() {
        let all = IORegistry.services(matching: "IOAccelerator")
        guard let first = all.first else { return nil }
        for extra in all.dropFirst() { IOObjectRelease(extra) }
        service = first
        name = IORegistry.property(first, "model") as? String
        cores = (IORegistry.property(first, "gpu-core-count") as? NSNumber)?.intValue
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    func sample() -> (util: Double?, memUsed: Double?) {
        guard let perf = IORegistry.property(service, "PerformanceStatistics") as? [String: Any] else {
            return (nil, nil)
        }
        let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue
        let mem = (perf["In use system memory"] as? NSNumber)?.doubleValue
        return (util, mem)
    }

    func dump() -> String {
        var lines = ["IOAccelerator class=\(IORegistry.className(service)) model=\(name ?? "?") cores=\(cores.map(String.init) ?? "?")"]
        if let perf = IORegistry.property(service, "PerformanceStatistics") as? [String: Any] {
            for (k, v) in perf.sorted(by: { $0.key < $1.key }) { lines.append("  \(k) = \(v)") }
        }
        return lines.joined(separator: "\n")
    }
}
