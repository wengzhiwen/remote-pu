import Foundation
import RPUIPC
import RPUProtocol
import Testing
@testable import RemotePUCore

/// A real line produced by rpu_collector.py on the 2× RTX PRO 4000 WSL2 host.
let wslHello = #"""
{"t":"hello","v":1,"agent":"rpu-collector/0.1.0","host":"gpu-wsl","os":"linux","os_version":"Ubuntu 24.04.4 LTS","kernel":"6.6.87.2-microsoft-standard-WSL2","arch":"x86_64","wsl":true,"model":null,"cpu":{"model":"AMD Ryzen 7 9850X3D 8-Core Processor","cores":16,"clusters":[{"name":"CPU","cores":16}]},"mem_total":25199570944,"swap_total":34359738368,"gpus":[{"idx":0,"uuid":"GPU-11111111-2222-3333-4444-000000000000","name":"NVIDIA RTX PRO 4000 Blackwell","mem_total":25655508992.0,"driver":"597.16","power_limit_w":145.0,"max_sm_mhz":3090.0,"pci_bus":"00000000:01:00.0","unified":false},{"idx":1,"uuid":"GPU-11111111-2222-3333-4444-000000000001","name":"NVIDIA RTX PRO 4000 Blackwell","mem_total":25655508992.0,"driver":"597.16","power_limit_w":145.0,"max_sm_mhz":3090.0,"pci_bus":"00000000:02:00.0","unified":false}],"fans":0,"caps":{"cpu_temp":false,"cpu_freq":false,"cpu_power":false,"gpu":"nvidia-smi","fans":false,"sys_power":false},"interval":1.0}
"""#

let wslSample = #"""
{"t":"s","ts":1792911296.601,"seq":1,"cpu":{"util":0.1,"cores":[0.0,0.0,null,1.0],"clusters":[{"name":"CPU","util":0.1}],"freq_mhz":null,"temp_c":null,"power_w":null,"load":[0.05,0.26,1.06]},"mem":{"used":11218829312,"total":25199570944,"available":13980741632,"swap_used":0,"swap_total":34359738368},"gpus":[{"idx":0,"util":0.0,"mem_util":0.0,"mem_used":25015877632.0,"mem_total":25655508992.0,"temp_c":29.0,"mem_temp_c":null,"power_w":5.83,"power_limit_w":145.0,"sm_mhz":180.0,"mem_mhz":405.0,"fan_pct":30.0,"pstate":"P8","throttle":[],"pcie_gen":5,"pcie_width":8},{"idx":1,"util":97.0,"mem_used":24639438848.0,"mem_total":25655508992.0,"temp_c":72.0,"power_w":140.1,"pstate":"P2","throttle":["sw_power_cap"]}],"fans":[]}
"""#

@Suite struct ProtocolTests {
    @Test func decodesCollectorHello() throws {
        guard case .hello(let h) = AgentMessage.decode(line: wslHello) else {
            Issue.record("not a hello")
            return
        }
        #expect(h.os == "linux")
        #expect(h.wsl == true)
        #expect(h.osVersion == "Ubuntu 24.04.4 LTS")
        #expect(h.cpu?.clusters?.first?.cores == 16)
        #expect(h.gpus?.count == 2)
        #expect(h.gpus?[1].maxSmMhz == 3090)
        #expect(h.gpus?[0].unified == false)
        #expect(h.caps?.cpuTemp == false)
        #expect(h.caps?.gpu == "nvidia-smi")
        #expect(h.gpuKeys[1] == "GPU-11111111-2222-3333-4444-000000000001")
    }

    @Test func decodesCollectorSample() throws {
        guard case .sample(let s) = AgentMessage.decode(line: wslSample) else {
            Issue.record("not a sample")
            return
        }
        #expect(s.seq == 1)
        #expect(s.cpu?.tempC == nil)
        #expect(s.cpu?.cores?.count == 4)
        #expect(s.cpu?.cores?[2] == nil)
        #expect(s.gpus?[1].throttle == ["sw_power_cap"])
        #expect(s.gpus?[0].pcieGen == 5)
        #expect(s.gpus?[0].memTempC == nil)
        #expect(s.mem?.swapTotal == 34_359_738_368)
    }

    @Test func roundTripsThroughAgentEncoder() throws {
        var s = SampleMessage(ts: 1_700_000_000.5)
        var g = GPUSample(idx: 0)
        g.powerLimitW = 145
        g.smMhz = 2805
        s.gpus = [g]
        var p = PowerSample()
        p.aneW = 0.5
        s.power = p
        let line = String(decoding: try RPUJSON.makeEncoder().encode(s), as: UTF8.self)
        #expect(line.contains("\"power_limit_w\":145"))
        #expect(line.contains("\"ane_w\":0.5"))
        guard case .sample(let back) = AgentMessage.decode(line: line) else {
            Issue.record("round trip failed")
            return
        }
        #expect(back == s)
    }

    @Test func ignoresNonJSONLines() {
        #expect(AgentMessage.decode(line: "Welcome to Ubuntu 24.04") == nil)
        #expect(AgentMessage.decode(line: "") == nil)
        if case .error = AgentMessage.decode(line: "{not json") {} else { Issue.record("expected error") }
    }

    @Test func collectorScriptIsInSync() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let onDisk = try String(contentsOf: repo.appendingPathComponent("collector/rpu_collector.py"), encoding: .utf8)
        #expect(CollectorScript.source + "\n" == onDisk, "run scripts/gen-collector.sh")
    }
}

@Suite struct ModelTests {
    @Test func metricRefParsing() {
        #expect(MetricRef(string: "cpu_util") == .node(.cpuUtil))
        #expect(MetricRef(string: "gpu:GPU-abc:util") == .gpu(key: "GPU-abc", .util))
        #expect(MetricRef(string: "gpu:a:b:temp") == .gpu(key: "a:b", .temp))
        #expect(MetricRef(string: "nope") == nil)
        #expect(MetricRef.gpu(key: "k", .smMhz).description == "gpu:k:sm_mhz")
    }

    @Test func ringBuffer() {
        var r = RingBuffer<Int>(capacity: 3)
        for i in 1...5 { r.append(i) }
        #expect(r.elements == [3, 4, 5])
        #expect(r.last == 5)
        #expect(r.count == 3)
    }

    @Test func thinSeriesAveragesAndKeepsMax() {
        let pts = (0..<10).map { SeriesPoint(t: Date(timeIntervalSince1970: Double($0)), avg: Double($0), max: Double($0) ) }
        let thinned = thinSeries(pts, to: 3)
        // stride = ceil(10/3) = 4 → chunks 0..3, 4..7, 8..9
        #expect(thinned.count == 3)
        #expect(thinned[0].avg == 1.5)   // mean 0,1,2,3
        #expect(thinned[0].max == 3)
        #expect(thinned[2].avg == 8.5)   // mean 8,9
        #expect(thinned[2].max == 9)
        #expect(thinned[0].t == pts[3].t) // chunk end timestamps the points
        #expect(thinSeries(pts, to: 10) == pts) // under the cap: untouched
    }

    @Test func nodeIDs() {
        #expect(NodeConfig.makeID(from: "GPU box #1") == "gpu-box-1")
        #expect(NodeConfig.makeID(from: "user@mac-b") == "user-mac-b")
    }

    @Test func nodeConfigToleratesMissingFields() throws {
        let n = try JSONDecoder().decode(NodeConfig.self, from: Data(#"{"name":"mac-b","target":"user@mac-b"}"#.utf8))
        #expect(n.id == "mac-b")
        #expect(n.kind == .ssh)
        #expect(n.auth == .system)
        #expect(n.interval == 1)
    }

    @Test func sshConfigParsing() {
        let text = """
        Host alpha
            HostName 192.0.2.10
            User ubuntu
        Host beta gamma
            User alice
            Port 2222
        Host *.internal
            User nobody
        Match host foo
            User bar
        """
        let hosts = SSHConfigParser.parse(text)
        #expect(hosts.map(\.alias) == ["alpha", "beta", "gamma"])
        #expect(hosts[0].hostName == "192.0.2.10")
        #expect(hosts[2].user == "alice")
        #expect(hosts[2].port == 2222)
    }

    @Test func probeParsing() {
        let r = ProbeResult.parse(["Welcome!", "Darwin", "arm64", "/usr/bin/python3", "26.6.2"])
        #expect(r == ProbeResult(os: "Darwin", arch: "arm64", python: "/usr/bin/python3", macOSVersion: "26.6.2"))
        let l = ProbeResult.parse(["Linux", "x86_64", "/usr/bin/python3", "-"])
        #expect(l?.macOSVersion == nil)
        #expect(ProbeResult.parse(["Linux"]) == nil)
    }

    @Test func sshArguments() {
        var node = NodeConfig(name: "mac-b", target: "user@mac-b", auth: .password)
        node.sshOptions = ["ProxyJump=bastion"]
        let cmd = SSHCommand(config: node, controlPath: "/tmp/cm/abc")
        let master = cmd.masterArguments()
        #expect(master.prefix(3) == ["-M", "-T", "-S"])
        #expect(master.last == SSHCommand.masterRemoteCommand)
        #expect(!master.contains("-N"))
        #expect(master.contains("BatchMode=no"))
        #expect(master.contains("ProxyJump=bastion"))
        #expect(master.dropLast().last == "user@mac-b")
        let client = cmd.clientArguments("uname")
        #expect(client.contains("ControlMaster=no"))
        #expect(client.suffix(2) == ["user@mac-b", "uname"])
        let sys = SSHCommand(config: NodeConfig(name: "x", target: "x"), controlPath: "/tmp/cm/x")
        #expect(sys.masterArguments().contains("BatchMode=yes"))
    }

    @Test func remoteScriptsQuoteSafely() {
        let s = RemoteScripts.linuxCollector(python: "/usr/bin/python3", interval: 1)
        #expect(s.hasPrefix("sh -c '"))
        #expect(s.contains("--interval 1.0"))
        #expect(RemoteScripts.agentStream(hash: "abc", interval: 2).contains("$HOME/.cache/remotepu/agents/abc/rpu-agent-mac"))
        let up = RemoteScripts.agentUpload(hash: "abc", sha256: String(repeating: "f", count: 64), gzipped: true)
        #expect(up.contains("gunzip -c"))
        #expect(up.contains("checksum mismatch"))
        #expect(shellQuote("it's") == "'it'\\''s'")
    }

    @Test func errorClassification() {
        #expect(RunnerError.classify(sshStderr: ["user@mac-b: Permission denied (publickey,password)."], status: 255).isTerminal)
        if case .network = RunnerError.classify(sshStderr: ["ssh: Could not resolve hostname nope"], status: 255) {} else {
            Issue.record("expected network")
        }
        if case .hostKey = RunnerError.classify(sshStderr: ["Host key verification failed."], status: 255) {} else {
            Issue.record("expected hostKey")
        }
    }

    @Test func demoGeneratorProducesSaneValues() {
        var gen = DemoGenerator(profile: .linuxGPU, name: "demo")
        let h = gen.hello(interval: 1)
        let s = gen.sample(at: Date())
        #expect(h.gpus?.count == s.gpus?.count)
        for g in s.gpus ?? [] {
            #expect((0...100).contains(g.util ?? -1))
        }
        #expect((0...100).contains(s.cpu?.util ?? -1))
    }
}
