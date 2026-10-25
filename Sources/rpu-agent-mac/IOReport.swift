import Foundation
import IOKit

/// Power (Energy Model) and DVFS residency from libIOReport — private API, loaded with
/// dlopen so that failure only disables these metrics. The approach mirrors macmon:
/// subscribe to channel groups, diff consecutive samples, convert energy to watts and
/// state residencies to utilisation / average frequency.
final class IOReportSampler {
    private typealias CopyChannelsFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> UnsafeMutableRawPointer?
    private typealias MergeFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeRawPointer?) -> Void
    private typealias CreateSubscriptionFn = @convention(c) (
        UnsafeRawPointer?, UnsafeMutableRawPointer, UnsafeMutablePointer<UnsafeMutableRawPointer?>, UInt64, UnsafeRawPointer?
    ) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CreateDeltaFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias GetStringFn = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    private typealias SimpleIntFn = @convention(c) (UnsafeRawPointer, Int32) -> Int64
    private typealias StateCountFn = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias StateNameFn = @convention(c) (UnsafeRawPointer, Int32) -> UnsafeRawPointer?
    private typealias StateResidencyFn = @convention(c) (UnsafeRawPointer, Int32) -> Int64

    struct Channel {
        var group: String
        var subgroup: String
        var name: String
        var unit: String
        var integer: Int64
        var states: [(name: String, residency: Int64)]
    }

    struct StateSummary {
        var name: String
        /// Fraction of time in a non-idle state.
        var activeRatio: Double
        var freqMhz: Double?
    }

    struct Reading {
        var cpuW: Double?
        var gpuW: Double?
        var aneW: Double?
        var dramW: Double?
        /// Per IOReport CPU complex, e.g. "ECPU", "PCPU", "PCPU1".
        var cpuClusters: [StateSummary] = []
        var gpu: StateSummary?
    }

    static let groups: [(String, String?)] = [
        ("Energy Model", nil),
        ("CPU Stats", "CPU Complex Performance States"),
        ("GPU Stats", "GPU Performance States"),
    ]

    private let createSamples: CreateSamplesFn
    private let createDelta: CreateDeltaFn
    private let getGroup: GetStringFn
    private let getSubGroup: GetStringFn
    private let getName: GetStringFn
    private let getUnit: GetStringFn
    private let simpleInt: SimpleIntFn
    private let stateCount: StateCountFn
    private let stateName: StateNameFn
    private let stateResidency: StateResidencyFn

    private let channels: CFMutableDictionary
    private let subscription: UnsafeMutableRawPointer
    private var previous: (CFDictionary, Double)?

    /// DVFS tables (MHz) from the pmgr node: "voltage-states*" → frequencies.
    let dvfs: [String: [Double]]

    init?() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let copyChannels = sym("IOReportCopyChannelsInGroup", CopyChannelsFn.self),
              let merge = sym("IOReportMergeChannels", MergeFn.self),
              let createSubscription = sym("IOReportCreateSubscription", CreateSubscriptionFn.self),
              let createSamples = sym("IOReportCreateSamples", CreateSamplesFn.self),
              let createDelta = sym("IOReportCreateSamplesDelta", CreateDeltaFn.self),
              let getGroup = sym("IOReportChannelGetGroup", GetStringFn.self),
              let getSubGroup = sym("IOReportChannelGetSubGroup", GetStringFn.self),
              let getName = sym("IOReportChannelGetChannelName", GetStringFn.self),
              let getUnit = sym("IOReportChannelGetUnitLabel", GetStringFn.self),
              let simpleInt = sym("IOReportSimpleGetIntegerValue", SimpleIntFn.self),
              let stateCount = sym("IOReportStateGetCount", StateCountFn.self),
              let stateName = sym("IOReportStateGetNameForIndex", StateNameFn.self),
              let stateResidency = sym("IOReportStateGetResidency", StateResidencyFn.self) else { return nil }
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.getGroup = getGroup
        self.getSubGroup = getSubGroup
        self.getName = getName
        self.getUnit = getUnit
        self.simpleInt = simpleInt
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency

        var merged: UnsafeMutableRawPointer?
        for (group, subgroup) in Self.groups {
            guard let ch = copyChannels(group as CFString, subgroup as CFString?, 0, 0, 0) else { continue }
            if let m = merged {
                merge(m, ch, nil)
                Unmanaged<CFMutableDictionary>.fromOpaque(ch).release()
            } else {
                merged = ch
            }
        }
        guard let mergedPtr = merged else { return nil }
        let dict = Unmanaged<CFMutableDictionary>.fromOpaque(mergedPtr).takeRetainedValue()
        guard let copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(dict), dict) else {
            return nil
        }
        channels = copy
        var subbed: UnsafeMutableRawPointer?
        guard let sub = createSubscription(nil, Unmanaged.passUnretained(copy).toOpaque(), &subbed, 0, nil) else {
            return nil
        }
        subscription = sub
        dvfs = Self.readDVFSTables()
        previous = takeSample().map { ($0, monotonicNow()) }
    }

    private func takeSample() -> CFDictionary? {
        guard let p = createSamples(subscription, Unmanaged.passUnretained(channels).toOpaque(), nil) else { return nil }
        return Unmanaged<CFDictionary>.fromOpaque(p).takeRetainedValue()
    }

    private func string(_ fn: GetStringFn, _ ch: UnsafeRawPointer) -> String {
        guard let p = fn(ch) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    /// Channels of the delta since the previous call, plus the elapsed seconds.
    func deltaChannels() -> ([Channel], Double)? {
        guard let current = takeSample() else { return nil }
        let now = monotonicNow()
        defer { previous = (current, now) }
        guard let (prev, prevTime) = previous else { return nil }
        let dt = now - prevTime
        guard dt > 0,
              let deltaPtr = createDelta(Unmanaged.passUnretained(prev).toOpaque(),
                                         Unmanaged.passUnretained(current).toOpaque(), nil) else { return nil }
        let delta = Unmanaged<CFDictionary>.fromOpaque(deltaPtr).takeRetainedValue()
        guard let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        var result: [Channel] = []
        result.reserveCapacity(items.count)
        for item in items {
            let ch = UnsafeRawPointer(Unmanaged.passUnretained(item).toOpaque())
            let group = string(getGroup, ch)
            var c = Channel(group: group, subgroup: string(getSubGroup, ch), name: string(getName, ch),
                            unit: string(getUnit, ch), integer: 0, states: [])
            if group == "Energy Model" {
                c.integer = simpleInt(ch, 0)
            } else {
                let n = stateCount(ch)
                for i in 0..<max(n, 0) {
                    let name: String
                    if let p = stateName(ch, i) {
                        name = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
                    } else {
                        name = "\(i)"
                    }
                    c.states.append((name, stateResidency(ch, i)))
                }
            }
            result.append(c)
        }
        return (result, dt)
    }

    static func joules(_ value: Int64, unit: String) -> Double {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": return Double(value) / 1e3
        case "uJ", "µJ": return Double(value) / 1e6
        case "nJ": return Double(value) / 1e9
        default: return Double(value) / 1e3
        }
    }

    static let idleStates: Set<String> = ["IDLE", "OFF", "DOWN"]

    /// Residency-weighted utilisation and frequency (state i+offset ↔ table[i]), as in macmon.
    static func summarize(_ ch: Channel, table: [Double]?) -> StateSummary {
        let total = ch.states.reduce(0.0) { $0 + Double($1.residency) }
        let offset = ch.states.firstIndex { !idleStates.contains($0.name.uppercased()) } ?? ch.states.count
        let active = ch.states[offset...].reduce(0.0) { $0 + Double($1.residency) }
        var freq: Double?
        if let table, !table.isEmpty, active > 0 {
            var acc = 0.0
            for i in 0..<min(table.count, ch.states.count - offset) {
                acc += Double(ch.states[i + offset].residency) / active * table[i]
            }
            freq = acc > 0 ? acc : nil
        }
        return StateSummary(name: ch.name, activeRatio: total > 0 ? active / total : 0, freqMhz: freq)
    }

    /// Per-cluster complexes only: ECPU, PCPU, PCPU1, MCPU0… (not PCPM / *_IDLE aggregates).
    static func isClusterChannel(_ name: String) -> Bool {
        name.range(of: #"^[A-Z]+CPU[0-9]*$"#, options: .regularExpression) != nil
    }

    static func activeStateCount(_ ch: Channel) -> Int {
        ch.states.filter { !idleStates.contains($0.name.uppercased()) }.count
    }

    /// DVFS table for a channel: the "-sram" table whose length equals the number of
    /// active states (M5: MCPU ↔ 15 entries, PCPU ↔ 20), else the conventional key.
    func table(for ch: Channel, conventional: [String]) -> [Double]? {
        let n = Self.activeStateCount(ch)
        let usable = dvfs.filter { ($0.value.max() ?? 0) >= 100 }
        let matches = usable.filter { $0.value.count == n }.sorted { a, b in
            (a.key.hasSuffix("-sram") ? 0 : 1, a.key) < (b.key.hasSuffix("-sram") ? 0 : 1, b.key)
        }
        if let best = matches.first { return best.value }
        for key in conventional { if let t = usable[key] { return t } }
        return nil
    }

    func cpuTable(for ch: Channel) -> [Double]? {
        let conventional: [String]
        switch ch.name.first {
        case "E": conventional = ["voltage-states1-sram", "voltage-states1"]
        case "P": conventional = ["voltage-states5-sram", "voltage-states5"]
        default: conventional = []
        }
        return table(for: ch, conventional: conventional)
    }

    func gpuTable(for ch: Channel) -> [Double]? {
        // GPU tables often have fewer entries than GPUPH states; map index-wise like macmon.
        for key in ["voltage-states9-sram", "voltage-states9"] {
            if let t = dvfs[key], (t.max() ?? 0) >= 100 { return t }
        }
        return table(for: ch, conventional: [])
    }

    func read() -> Reading? {
        guard let (chans, dt) = deltaChannels() else { return nil }
        var r = Reading()
        var cpuTotal: Double?
        var cpuParts = 0.0
        var anyCPUPart = false
        var ane = 0.0, anyANE = false
        var dram = 0.0, anyDRAM = false
        for ch in chans {
            switch ch.group {
            case "Energy Model":
                let w = Self.joules(ch.integer, unit: ch.unit) / dt
                if ch.name == "CPU Energy" {
                    cpuTotal = w
                } else if ch.name.hasSuffix("CPU Energy") {
                    cpuParts += w
                    anyCPUPart = true
                } else if ch.name == "GPU Energy" {
                    r.gpuW = w
                } else if ch.name.hasPrefix("ANE") {
                    ane += w
                    anyANE = true
                } else if ch.name.hasPrefix("DRAM") {
                    dram += w
                    anyDRAM = true
                }
            case "CPU Stats" where ch.subgroup == "CPU Complex Performance States" && Self.isClusterChannel(ch.name):
                r.cpuClusters.append(Self.summarize(ch, table: cpuTable(for: ch)))
            case "GPU Stats" where ch.subgroup == "GPU Performance States" && ch.name == "GPUPH":
                r.gpu = Self.summarize(ch, table: gpuTable(for: ch))
            default:
                break
            }
        }
        r.cpuW = cpuTotal ?? (anyCPUPart ? cpuParts : nil)
        r.aneW = anyANE ? ane : nil
        r.dramW = anyDRAM ? dram : nil
        return r
    }

    static func readDVFSTables() -> [String: [Double]] {
        var tables: [String: [Double]] = [:]
        for entry in IORegistry.services(matching: "AppleARMIODevice") {
            defer { IOObjectRelease(entry) }
            guard IORegistry.name(entry) == "pmgr" else { continue }
            for (key, value) in IORegistry.properties(entry) where key.hasPrefix("voltage-states") {
                guard let data = value as? Data, data.count >= 8 else { continue }
                var freqs: [Double] = []
                data.withUnsafeBytes { raw in
                    for i in stride(from: 0, to: data.count - 7, by: 8) {
                        let f = raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)
                        if f > 0 { freqs.append(Double(f)) }
                    }
                }
                guard let maxF = freqs.max() else { continue }
                // Units differ between generations: Hz (M1–M3) or kHz (newer).
                let scale: Double = maxF > 1e8 ? 1e6 : (maxF > 1e5 ? 1e3 : 1)
                tables[key] = freqs.map { ($0 / scale).rounded() }
            }
        }
        return tables
    }

    func dump() -> String {
        var lines: [String] = []
        for (k, v) in dvfs.sorted(by: { $0.key < $1.key }) {
            lines.append("dvfs \(k): \(v.map { String(Int($0)) }.joined(separator: " ")) MHz")
        }
        Thread.sleep(forTimeInterval: 1)
        guard let (chans, dt) = deltaChannels() else {
            lines.append("no IOReport delta")
            return lines.joined(separator: "\n")
        }
        lines.append(String(format: "delta over %.3fs, %d channels", dt, chans.count))
        for ch in chans {
            if ch.group == "Energy Model" {
                let w = Self.joules(ch.integer, unit: ch.unit) / dt
                lines.append("[\(ch.group)] \(ch.name) = \(ch.integer) \(ch.unit) → \(String(format: "%.3f", w)) W")
            } else {
                let states = ch.states.map { "\($0.name):\($0.residency)" }.joined(separator: " ")
                lines.append("[\(ch.group) / \(ch.subgroup)] \(ch.name) (\(ch.states.count) states) \(states)")
            }
        }
        Thread.sleep(forTimeInterval: 1)
        if let r = read() {
            lines.append("summary: cpuW=\(r.cpuW.map { String(format: "%.2f", $0) } ?? "-") "
                + "gpuW=\(r.gpuW.map { String(format: "%.2f", $0) } ?? "-") "
                + "aneW=\(r.aneW.map { String(format: "%.2f", $0) } ?? "-")")
            for c in r.cpuClusters {
                lines.append("  cpu \(c.name): active=\(String(format: "%.1f", c.activeRatio * 100))% freq=\(c.freqMhz.map { String(Int($0)) } ?? "-")")
            }
            if let g = r.gpu {
                lines.append("  gpu \(g.name): active=\(String(format: "%.1f", g.activeRatio * 100))% freq=\(g.freqMhz.map { String(Int($0)) } ?? "-")")
            }
        }
        return lines.joined(separator: "\n")
    }
}
