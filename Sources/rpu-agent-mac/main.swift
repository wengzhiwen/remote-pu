// rpu-agent-mac — Apple Silicon collector for RemotePU (NDJSON v1 on stdout).
//
// Runs unprivileged, locally (spawned by the app) or on a remote Mac (uploaded over
// ssh to ~/.cache/remotepu/agents/<hash>/). Exits when stdout closes.
//
//   rpu-agent-mac [--interval SEC] [--count N] [--no-ioreport] [--no-smc] [--no-hid]
//   rpu-agent-mac --once            pretty-print hello + one sample
//   rpu-agent-mac --dump-topology   core clusters / device tree
//   rpu-agent-mac --dump-smc [--all] SMC keys (temperature/fan/power by default)
//   rpu-agent-mac --dump-hid        HID thermal sensors
//   rpu-agent-mac --dump-ioreport   IOReport channels + DVFS tables
//   rpu-agent-mac --dump-gpu        IOAccelerator statistics
//   rpu-agent-mac --version
import Darwin
import Foundation
import IOKit
import RPUProtocol

let agentVersion = "0.1.0"

struct Options {
    var interval = 1.0
    var count = 0
    var useIOReport = true
    var useSMC = true
    var useHID = true
    var once = false
    var dump: String?
    var dumpAll = false
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--interval": o.interval = max(0.2, Double(args.isEmpty ? "1" : args.removeFirst()) ?? 1)
        case "--count": o.count = Int(args.isEmpty ? "0" : args.removeFirst()) ?? 0
        case "--no-ioreport": o.useIOReport = false
        case "--no-smc": o.useSMC = false
        case "--no-hid": o.useHID = false
        case "--once": o.once = true
        case "--all": o.dumpAll = true
        case "--version":
            print("rpu-agent-mac \(agentVersion) (protocol v\(RPUProtocolInfo.version))")
            exit(0)
        case let d where d.hasPrefix("--dump-"):
            o.dump = String(d.dropFirst("--dump-".count))
        default:
            FileHandle.standardError.write(Data("rpu-agent-mac: unknown option \(a)\n".utf8))
            exit(2)
        }
    }
    return o
}

final class Agent {
    let options: Options
    let topology = CPUTopology.detect()
    let cpu: CPUSampler
    let gpu = AppleGPUSampler()
    let smcSensors: SMCSensors?
    let hid: HIDTemperatures?
    let ioreport: IOReportSampler?
    var seq = 0

    init(options: Options) {
        self.options = options
        cpu = CPUSampler(topology: topology)
        smcSensors = options.useSMC ? SMC().map { SMCSensors(smc: $0) } : nil
        // HID is only needed when the SMC has no recognisable CPU die sensors.
        hid = (options.useHID && (smcSensors?.cpuKeys.isEmpty ?? true)) ? HIDTemperatures() : nil
        ioreport = options.useIOReport ? IOReportSampler() : nil
    }

    func hello() -> HelloMessage {
        var h = HelloMessage()
        h.agent = "rpu-agent-mac/\(agentVersion)"
        h.host = Sysctl.string("kern.hostname").map { $0.hasSuffix(".local") ? String($0.dropLast(6)) : $0 }
        h.os = "macos"
        h.osVersion = Sysctl.string("kern.osproductversion")
        h.kernel = Sysctl.string("kern.osrelease")
        var uts = utsname()
        uname(&uts)
        h.arch = withUnsafeBytes(of: &uts.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        // Marketing name ("MacBook Pro (14-inch, M5 Pro)"); hw.model ("Mac17,9") as fallback.
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if product != 0 {
            h.model = IORegistry.string(fromData: IORegistry.property(product, "product-name"))
            IOObjectRelease(product)
        }
        if h.model?.isEmpty ?? true { h.model = Sysctl.string("hw.model") }
        let brand = Sysctl.string("machdep.cpu.brand_string")
        h.cpu = CPUInfo(model: brand, cores: topology.logicalCPUs, clusters: topology.clusterInfo)
        h.memTotal = MemorySampler.totalBytes
        h.swapTotal = MemorySampler.swap()?.total
        var g = GPUInfo(idx: 0)
        g.uuid = "apple-gpu-0"
        g.name = gpu?.name ?? brand.map { "\($0) GPU" } ?? "Apple GPU"
        g.cores = gpu?.cores
        g.unified = true
        h.gpus = [g]
        h.fans = smcSensors?.fanCount ?? 0
        var caps = Caps()
        caps.cpuTemp = !(smcSensors?.cpuKeys.isEmpty ?? true) || hid != nil
        caps.cpuFreq = ioreport.map { !$0.dvfs.isEmpty } ?? false
        caps.cpuPower = ioreport != nil
        caps.gpu = gpu != nil ? "ioaccelerator" : (ioreport != nil ? "ioreport" : nil)
        caps.fans = (smcSensors?.fanCount ?? 0) > 0
        caps.sysPower = smcSensors?.hasSystemPower ?? false
        caps.smc = smcSensors != nil
        caps.ioreport = ioreport != nil
        h.caps = caps
        h.interval = options.interval
        return h
    }

    /// IOReport cluster frequencies keyed by our topology cluster name.
    private func clusterFrequencies(_ r: IOReportSampler.Reading?) -> [String: Double] {
        guard let r else { return [:] }
        // Group complexes by leading letter (PCPU + PCPU1 → "P", MCPU0 + MCPU1 → "M") and
        // average the frequencies of the ones that were active.
        var byLetter: [String: [Double]] = [:]
        for c in r.cpuClusters {
            guard let f = c.freqMhz, c.activeRatio > 0, let first = c.name.first else { continue }
            byLetter[String(first), default: []].append(f)
        }
        guard !byLetter.isEmpty else { return [:] }
        var result: [String: Double] = [:]
        for cluster in topology.clusters {
            // Device-tree letter when known; else the perflevel name ("Efficiency" ↔ E…).
            guard let letter = cluster.letter ?? cluster.name.first.map(String.init),
                  let freqs = byLetter[letter] else { continue }
            result[cluster.name] = (freqs.reduce(0, +) / Double(freqs.count)).rounded()
        }
        return result
    }

    func sample() -> SampleMessage {
        seq += 1
        var s = SampleMessage(ts: Date().timeIntervalSince1970.rounded(3))
        s.seq = seq
        let reading = ioreport?.read()

        var c = CPUSample()
        let cores = cpu.sampleCores()
        c.cores = cores
        let valid = cores.compactMap { $0 }
        if !valid.isEmpty { c.util = (valid.reduce(0, +) / Double(valid.count)).rounded(1) }
        let freqs = clusterFrequencies(reading)
        c.clusters = topology.clusters.map { cl in
            let vals = cl.cpus.compactMap { $0 < cores.count ? cores[$0] : nil }
            let util = vals.isEmpty ? nil : (vals.reduce(0, +) / Double(vals.count)).rounded(1)
            return ClusterSample(name: cl.name, util: util, freqMhz: freqs[cl.name])
        }
        if !freqs.isEmpty {
            // Highest-performance cluster's frequency as the headline number.
            let top = topology.clusters.min { $0.perfLevel < $1.perfLevel }
            c.freqMhz = top.flatMap { freqs[$0.name] } ?? freqs.values.max()
        }
        if let t = smcSensors?.cpuTemperature() ?? hid?.cpuTemperature() {
            c.tempC = t.avg.rounded(1)
            c.tempMaxC = t.max.rounded(1)
        }
        c.powerW = reading?.cpuW.rounded(2)
        c.load = CPUSampler.loadAverage()
        s.cpu = c

        s.mem = MemorySampler.sample()

        var g = GPUSample(idx: 0)
        if let gs = gpu?.sample() {
            g.util = gs.util
            g.memUsed = gs.memUsed
        }
        if g.util == nil, let active = reading?.gpu?.activeRatio { g.util = (active * 100).rounded(1) }
        g.smMhz = reading?.gpu?.freqMhz?.rounded()
        g.tempC = smcSensors?.gpuTemperature()?.avg.rounded(1)
        g.powerW = reading?.gpuW.rounded(2)
        s.gpus = [g]

        if let sensors = smcSensors, sensors.fanCount > 0 {
            s.fans = sensors.fans().enumerated().map { i, f in
                var fan = FanSample(idx: i)
                fan.rpm = f.rpm.map { $0.rounded() }
                fan.minRpm = f.min.map { $0.rounded() }
                fan.maxRpm = f.max.map { $0.rounded() }
                return fan
            }
        }

        var p = PowerSample()
        p.systemW = smcSensors?.systemPower().rounded(2)
        p.cpuW = reading?.cpuW.rounded(2)
        p.gpuW = reading?.gpuW.rounded(2)
        p.aneW = reading?.aneW.rounded(2)
        p.dramW = reading?.dramW.rounded(2)
        s.power = p
        return s
    }
}

let encoder = RPUJSON.makeEncoder()

func emit<T: Encodable>(_ value: T) {
    guard var data = try? encoder.encode(value) else { return }
    data.append(0x0A)
    do {
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch {
        exit(0) // reader went away
    }
}

func prettyPrint<T: Encodable>(_ value: T) {
    let e = RPUJSON.makeEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? e.encode(value) { print(String(decoding: d, as: UTF8.self)) }
}

signal(SIGPIPE, SIG_IGN)
let options = parseOptions()

if let dump = options.dump {
    switch dump {
    case "topology":
        print(CPUTopology.detect().dump())
    case "smc":
        guard let smc = SMC() else { print("SMC unavailable"); exit(1) }
        print(SMCSensors(smc: smc).dump(all: options.dumpAll))
    case "hid":
        guard let hid = HIDTemperatures() else { print("HID sensors unavailable"); exit(1) }
        for (name, value) in hid.readAll().sorted(by: { $0.name < $1.name }) {
            print(String(format: "%-28@ %.2f", name as NSString, value))
        }
    case "ioreport":
        guard let io = IOReportSampler() else { print("IOReport unavailable"); exit(1) }
        print(io.dump())
    case "gpu":
        print(AppleGPUSampler()?.dump() ?? "IOAccelerator unavailable")
    default:
        FileHandle.standardError.write(Data("unknown dump: \(dump)\n".utf8))
        exit(2)
    }
    exit(0)
}

let agent = Agent(options: options)

if options.once {
    prettyPrint(agent.hello())
    Thread.sleep(forTimeInterval: options.interval)
    prettyPrint(agent.sample())
    exit(0)
}

emit(agent.hello())
let parent = getppid()
var next = monotonicNow()
while true {
    next += options.interval
    let delay = next - monotonicNow()
    if delay > 0 {
        Thread.sleep(forTimeInterval: delay)
    } else if delay < -options.interval {
        next = monotonicNow() // fell behind (e.g. after sleep); resync
    }
    emit(agent.sample())
    if options.count > 0, agent.seq >= options.count { break }
    if getppid() != parent { break } // launcher died; we were re-parented
}
