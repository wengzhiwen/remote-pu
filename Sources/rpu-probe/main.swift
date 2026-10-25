// rpu-probe — headless end-to-end check of the RemotePU pipeline (ssh master → probe →
// deploy → stream → decode), using exactly the code the app runs.
//
//   rpu-probe [options] <node>...
//     node: local | demo | demo-mac | <ssh target> (alias or user@host)
//   options:
//     --interval SEC            sample interval (default 1)
//     --count N                 stop after N samples from every node (default: run until Ctrl-C)
//     --duration SEC            stop after SEC seconds
//     --json                    print raw NDJSON (prefixed with the node id) instead of summaries
//     --password TARGET=ENVVAR  use password auth for TARGET, reading the password from $ENVVAR
//     --ask-password TARGET     use password auth for TARGET, prompting on the terminal
//     --history PATH            also write samples into a HistoryStore at PATH and print stats
//
//   e.g. MAC_B_PW=... rpu-probe --count 5 local user@gpu-wsl --password user@mac-b=MAC_B_PW user@mac-b
import Darwin
import Foundation
import RemotePUCore
import RPUProtocol

ignoreSIGPIPE()
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("rpu-probe: \(msg)\n".utf8))
    exit(2)
}

var interval = 1.0
var count = 0
var duration: Double?
var json = false
var historyPath: String?
var passwordEnv: [String: String] = [:]
var askPassword: Set<String> = []
var specs: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    func next() -> String {
        guard !args.isEmpty else { fail("\(a) needs a value") }
        return args.removeFirst()
    }
    switch a {
    case "--interval": interval = Double(next()) ?? 1
    case "--count": count = Int(next()) ?? 0
    case "--duration": duration = Double(next())
    case "--json": json = true
    case "--history": historyPath = next()
    case "--password":
        let v = next()
        guard let eq = v.firstIndex(of: "=") else { fail("--password expects TARGET=ENVVAR") }
        passwordEnv[String(v[..<eq])] = String(v[v.index(after: eq)...])
    case "--ask-password": askPassword.insert(next())
    case "-h", "--help":
        print("usage: rpu-probe [--interval S] [--count N] [--duration S] [--json] [--password T=VAR] [--ask-password T] [--history PATH] <node>...")
        exit(0)
    default:
        if a.hasPrefix("--") { fail("unknown option \(a)") }
        specs.append(a)
    }
}
guard !specs.isEmpty else { fail("no nodes given (try: rpu-probe local)") }

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rpu-probe-\(getpid())", isDirectory: true)
let paths = RPUPaths(dataDir: tmp)
try? paths.ensureDirectories()
let secrets = LayeredSecretStore(keychain: nil)
let broker = try? AskpassBroker(socketPath: paths.askpassSocket)

var nodes: [NodeConfig] = []
for spec in specs {
    var node: NodeConfig
    switch spec {
    case "local": node = .local()
    case "demo": node = NodeConfig(id: "demo", name: "demo", kind: .demo, demoProfile: "linux-2gpu")
    case "demo-mac": node = NodeConfig(id: "demo-mac", name: "demo-mac", kind: .demo, demoProfile: "mac")
    default: node = NodeConfig(id: NodeConfig.makeID(from: spec), name: spec, kind: .ssh, target: spec)
    }
    node.interval = interval
    if let envVar = passwordEnv[spec] {
        guard let pw = ProcessInfo.processInfo.environment[envVar] else { fail("$\(envVar) is not set") }
        node.auth = .password
        try? secrets.setPassword(pw, for: node.id, persist: false)
    } else if askPassword.contains(spec) {
        guard let p = getpass("Password for \(spec): ") else { fail("no password") }
        node.auth = .password
        try? secrets.setPassword(String(cString: p), for: node.id, persist: false)
    }
    nodes.append(node)
}

let agent = HelperLocator.find("rpu-agent-mac")
let askpass = HelperLocator.find("rpu-askpass")
if agent == nil { FileHandle.standardError.write(Data("rpu-probe: warning: rpu-agent-mac not found next to this binary\n".utf8)) }
var env = RunnerEnvironment(paths: paths, agentBinary: agent, askpassHelper: askpass, broker: broker, secrets: secrets)
RPULog.shared.echoToStderr = ProcessInfo.processInfo.environment["RPU_VERBOSE"] != nil
env.log = RPULog.shared

let history = historyPath.flatMap { try? HistoryStore(path: URL(fileURLWithPath: $0)) }
let manager = NodeManager(env: env)
let encoder = RPUJSON.makeEncoder()

func gib(_ v: Double?) -> String { v.map { String(format: "%.1f", $0 / 1_073_741_824) } ?? "-" }
func num(_ v: Double?, _ fmt: String = "%.0f") -> String { v.map { String(format: fmt, $0) } ?? "-" }

func summary(_ s: SampleMessage) -> String {
    var parts: [String] = []
    if let c = s.cpu {
        var cpu = "cpu \(num(c.util, "%.1f"))% \(num(c.tempC, "%.1f"))°C"
        if let f = c.freqMhz { cpu += " \(Int(f))MHz" }
        if let p = c.powerW { cpu += " \(num(p, "%.1f"))W" }
        if let cl = c.clusters, cl.count > 1 {
            cpu += " [" + cl.map { "\($0.name) \(num($0.util, "%.0f"))%\($0.freqMhz.map { "@\(Int($0))" } ?? "")" }.joined(separator: ", ") + "]"
        }
        parts.append(cpu)
    }
    if let m = s.mem { parts.append("mem \(gib(m.used))/\(gib(m.total))G swap \(gib(m.swapUsed))G\(m.pressure.map { " \($0)" } ?? "")") }
    for g in s.gpus ?? [] {
        var gpu = "gpu\(g.idx) \(num(g.util))% \(num(g.tempC))°C"
        if g.memTotal != nil || g.memUsed != nil { gpu += " \(gib(g.memUsed))/\(gib(g.memTotal))G" }
        if let p = g.powerW { gpu += " \(num(p, "%.1f"))W" }
        if let sm = g.smMhz { gpu += " \(Int(sm))MHz" }
        if let f = g.fanPct { gpu += " fan \(Int(f))%" }
        if let ps = g.pstate { gpu += " \(ps)" }
        if let t = g.throttle?.filter({ $0 != "gpu_idle" }), !t.isEmpty { gpu += " ⚠︎" + t.joined(separator: ",") }
        parts.append(gpu)
    }
    if let fans = s.fans, !fans.isEmpty { parts.append("fans " + fans.map { num($0.rpm) }.joined(separator: "/") + "rpm") }
    if let p = s.power, let w = p.systemW { parts.append("sys \(num(w, "%.1f"))W") }
    return parts.joined(separator: " | ")
}

let deadline = duration.map { Date().addingTimeInterval($0) }

/// Only touched from the main queue (MainActor tasks and the SIGINT source).
final class ProbeState: @unchecked Sendable {
    var sampleCounts: [String: Int] = [:]
    var gpuKeys: [String: [Int: String]] = [:]
    var done = false
}

let state = ProbeState()

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { state.done = true }
sigint.resume()

@MainActor func handle(_ e: NodeManagerEvent) async {
    let id = e.nodeID
    switch e.event {
    case .status(let st):
        print("[\(id)] \(st.phase.rawValue)\(st.message.map { ": \($0)" } ?? "")\(st.retryAt.map { " (retry at \($0.formatted(date: .omitted, time: .standard)))" } ?? "")")
    case .hello(let h):
        state.gpuKeys[id] = h.gpuKeys
        if json {
            if let d = try? encoder.encode(h) { print("\(id)\t\(String(decoding: d, as: UTF8.self))") }
        } else {
            let gpus = (h.gpus ?? []).map { $0.name ?? "GPU" }
            let clusters = (h.cpu?.clusters ?? []).map { "\($0.name)×\($0.cores)" }.joined(separator: " + ")
            print("[\(id)] hello \(h.agent ?? "?") host=\(h.host ?? "?") \(h.os ?? "?") \(h.osVersion ?? "") "
                + "cpu=\(h.cpu?.model ?? "?") (\(clusters)) mem=\(gib(h.memTotal))G gpus=\(gpus) "
                + "caps=\(h.caps.flatMap { try? String(decoding: encoder.encode($0), as: UTF8.self) } ?? "{}")")
        }
    case .sample(let s):
        if json {
            if let d = try? encoder.encode(s) { print("\(id)\t\(String(decoding: d, as: UTF8.self))") }
        } else {
            print("[\(id)] #\(s.seq ?? 0) \(summary(s))")
        }
        if let history { await history.ingest(nodeID: id, sample: s, gpuKeys: state.gpuKeys[id] ?? [:]) }
        state.sampleCounts[id, default: 0] += 1
        if count > 0, nodes.allSatisfy({ (state.sampleCounts[$0.id] ?? 0) >= count }) { state.done = true }
    case .agentError(let msg):
        print("[\(id)] collector error: \(msg)")
    }
}

Task { @MainActor in
    await manager.apply(nodes)
    let consumer = Task { @MainActor in
        for await e in manager.events { await handle(e) }
    }
    while !state.done {
        if let deadline, Date() >= deadline { break }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    await manager.stopAll()
    consumer.cancel()
    if let history {
        try? await history.flush(includeCurrent: true)
        if let stats = try? await history.stats() { print("history rows: \(stats)") }
    }
    try? FileManager.default.removeItem(at: tmp)
    let ok = count == 0 || nodes.allSatisfy { (state.sampleCounts[$0.id] ?? 0) >= count }
    exit(ok ? 0 : 1)
}

dispatchMain()
