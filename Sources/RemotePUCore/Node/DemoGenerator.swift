import Foundation
import RPUProtocol

/// Synthetic, smoothly varying data for UI work without hardware (`--demo`, `demo.set`).
public struct DemoGenerator: Sendable {
    public enum Profile: String, Sendable, CaseIterable {
        case linuxGPU = "linux-2gpu"
        case mac
    }

    public let profile: Profile
    public let name: String
    private var seq = 0
    private let phase: Double

    public init(profile: Profile, name: String) {
        self.profile = profile
        self.name = name
        phase = Double(abs(name.hashValue % 1000)) / 100
    }

    private func wave(_ t: Double, period: Double, offset: Double = 0) -> Double {
        (sin((t / period + offset + phase) * 2 * .pi) + 1) / 2
    }

    private func jitter(_ amount: Double) -> Double { Double.random(in: -amount...amount) }

    public func hello(interval: Double) -> HelloMessage {
        var h = HelloMessage()
        h.agent = "demo/1"
        h.host = name
        h.interval = interval
        switch profile {
        case .linuxGPU:
            h.os = "linux"
            h.osVersion = "Ubuntu 24.04 LTS (demo)"
            h.kernel = "6.8.0-demo"
            h.arch = "x86_64"
            h.cpu = CPUInfo(model: "AMD EPYC 9354 32-Core (demo)", cores: 64, clusters: [ClusterInfo(name: "CPU", cores: 64)])
            h.memTotal = 512 * 1_073_741_824
            h.swapTotal = 8 * 1_073_741_824
            h.gpus = (0..<2).map { i in
                var g = GPUInfo(idx: i)
                g.uuid = "GPU-demo-\(name)-\(i)"
                g.name = "NVIDIA RTX 6000 Ada (demo)"
                g.memTotal = 48 * 1_073_741_824
                g.powerLimitW = 300
                g.maxSmMhz = 2505
                g.driver = "580.00"
                g.unified = false
                return g
            }
            var c = Caps()
            c.cpuTemp = true
            c.cpuFreq = true
            c.gpu = "demo"
            h.caps = c
        case .mac:
            h.os = "macos"
            h.osVersion = "26.0 (demo)"
            h.arch = "arm64"
            h.model = "Mac17,9"
            h.cpu = CPUInfo(model: "Apple M5 Pro (demo)", cores: 18,
                            clusters: [ClusterInfo(name: "Performance", cores: 12), ClusterInfo(name: "Super", cores: 6)])
            h.memTotal = 64 * 1_073_741_824
            var g = GPUInfo(idx: 0)
            g.uuid = "apple-gpu-0"
            g.name = "Apple M5 Pro GPU (demo)"
            g.cores = 20
            g.unified = true
            h.gpus = [g]
            h.fans = 2
            var c = Caps()
            c.cpuTemp = true
            c.cpuPower = true
            c.gpu = "demo"
            c.fans = true
            c.sysPower = true
            h.caps = c
        }
        return h
    }

    public mutating func sample(at date: Date) -> SampleMessage {
        seq += 1
        let t = date.timeIntervalSince1970
        var s = SampleMessage(ts: t)
        s.seq = seq
        var c = CPUSample()
        let base = 15 + 60 * wave(t, period: 90)
        let cores: Int = profile == .linuxGPU ? 64 : 18
        c.cores = (0..<cores).map { i in min(100, max(0, base + 25 * wave(t, period: 13, offset: Double(i) / 7) - 12 + jitter(4))) }
        c.util = c.cores!.compactMap { $0 }.reduce(0, +) / Double(cores)
        c.tempC = 42 + 0.45 * base + jitter(0.6)
        c.freqMhz = 2400 + 1100 * wave(t, period: 40)
        c.load = [base / 100 * Double(cores) / 2, base / 120 * Double(cores) / 2, base / 140 * Double(cores) / 2]
        var m = MemSample()
        switch profile {
        case .linuxGPU:
            c.clusters = [ClusterSample(name: "CPU", util: c.util, freqMhz: c.freqMhz)]
            m.total = 512 * 1_073_741_824
            m.used = (180 + 60 * wave(t, period: 300)) * 1_073_741_824
            m.swapTotal = 8 * 1_073_741_824
            m.swapUsed = 0.2 * 1_073_741_824
            s.gpus = (0..<2).map { i in
                var g = GPUSample(idx: i)
                let busy = i == 0 ? 85 + 14 * wave(t, period: 20) : 100 * max(0, wave(t, period: 240) - 0.3) / 0.7
                g.util = min(100, max(0, busy + jitter(2)))
                g.memUtil = (g.util ?? 0) * 0.55
                g.memTotal = 48 * 1_073_741_824
                g.memUsed = (i == 0 ? 41 : 12 + 20 * wave(t, period: 240)) * 1_073_741_824
                g.tempC = 38 + 0.42 * (g.util ?? 0) + jitter(0.5)
                g.powerW = 30 + 2.6 * (g.util ?? 0)
                g.powerLimitW = 300
                g.smMhz = 300 + 22 * (g.util ?? 0)
                g.memMhz = 10_001
                g.fanPct = 30 + 0.5 * (g.util ?? 0)
                g.pstate = (g.util ?? 0) > 5 ? "P2" : "P8"
                g.throttle = (g.powerW ?? 0) > 280 ? ["sw_power_cap"] : []
                g.pcieGen = 4
                g.pcieWidth = 16
                return g
            }
        case .mac:
            let perf = c.cores!.prefix(12).compactMap { $0 }
            let sup = c.cores!.suffix(6).compactMap { $0 }
            c.clusters = [ClusterSample(name: "Performance", util: perf.reduce(0, +) / 12, freqMhz: 2900),
                          ClusterSample(name: "Super", util: sup.reduce(0, +) / 6, freqMhz: 4300)]
            c.powerW = 3 + 0.25 * base
            m.total = 64 * 1_073_741_824
            m.used = (28 + 8 * wave(t, period: 200)) * 1_073_741_824
            m.swapTotal = 2 * 1_073_741_824
            m.swapUsed = 0.4 * 1_073_741_824
            m.pressure = "normal"
            var g = GPUSample(idx: 0)
            g.util = 100 * max(0, wave(t, period: 60) - 0.4) / 0.6
            g.tempC = 40 + 0.3 * (g.util ?? 0)
            g.powerW = 0.2 * (g.util ?? 0)
            g.smMhz = 400 + 10 * (g.util ?? 0)
            g.memUsed = 6 * 1_073_741_824
            s.gpus = [g]
            s.fans = (0..<2).map { i in
                var f = FanSample(idx: i)
                f.rpm = base > 50 ? 1800 + 30 * base : 0
                f.minRpm = 1200
                f.maxRpm = 6500
                return f
            }
            var p = PowerSample()
            p.cpuW = c.powerW
            p.gpuW = g.powerW
            p.aneW = 0
            p.systemW = 8 + (c.powerW ?? 0) + (g.powerW ?? 0)
            s.power = p
        }
        m.available = (m.total ?? 0) - (m.used ?? 0)
        s.cpu = c
        s.mem = m
        return s
    }
}
