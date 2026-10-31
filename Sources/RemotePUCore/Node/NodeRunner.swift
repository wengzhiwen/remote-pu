import Foundation
import RPUProtocol

public enum NodeEvent: Sendable {
    case status(NodeStatus)
    case hello(HelloMessage)
    case sample(SampleMessage)
    /// Non-fatal `{"t":"err"}` line from the collector.
    case agentError(String)
}

/// Everything a runner needs from its host process (app or rpu-probe).
public struct RunnerEnvironment: Sendable {
    public var paths: RPUPaths
    public var sshPath = "/usr/bin/ssh"
    /// rpu-agent-mac used for the local node and uploaded to remote Macs.
    public var agentBinary: String?
    /// gzip of `agentBinary` (smaller upload); made by scripts/mac.sh.
    public var agentGzip: String?
    /// rpu-askpass, required for password authentication.
    public var askpassHelper: String?
    public var broker: AskpassBroker?
    public var secrets: SecretStore
    public var collectorScript: String = CollectorScript.source
    public var log: RPULog = .shared

    public init(paths: RPUPaths, agentBinary: String?, askpassHelper: String?, broker: AskpassBroker?, secrets: SecretStore) {
        self.paths = paths
        self.agentBinary = agentBinary
        agentGzip = agentBinary.flatMap(HelperLocator.findAgentGzip(agentPath:))
        self.askpassHelper = askpassHelper
        self.broker = broker
        self.secrets = secrets
    }
}

/// Drives one node: connect → probe → (deploy) → stream, with stale detection and
/// exponential-backoff reconnects. Auth/host-key failures wait for `retryNow()`.
public actor NodeRunner {
    public let config: NodeConfig
    private let env: RunnerEnvironment
    private let emit: @Sendable (NodeEvent) -> Void
    private let decoder = RPUJSON.makeDecoder()

    private var loopTask: Task<Void, Never>?
    private var master: ManagedProcess?
    private var masterExit: Int32?
    private var stream: ManagedProcess?
    private var askToken: String?
    private var wakeRequested = false
    private var lastSampleAt = Date.distantPast
    private(set) var status = NodeStatus(phase: .idle)

    public init(config: NodeConfig, env: RunnerEnvironment, emit: @escaping @Sendable (NodeEvent) -> Void) {
        self.config = config
        self.env = env
        self.emit = emit
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await self.runLoop() }
    }

    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
        await teardown()
        setStatus(.disabled)
    }

    /// Skip the backoff wait / clear an auth failure and reconnect now.
    public func retryNow() {
        wakeRequested = true
        stream?.terminate(grace: 1)
    }

    public func currentStatus() -> NodeStatus { status }

    /// Runs a one-shot `sh -c` script over this node's ControlMaster (used by
    /// the AetherSwitch integration). Only valid while the master is up; stream
    /// sampling continues unaffected on its own multiplexed client.
    public func runRemote(_ script: String, timeout: Double = 60) async throws -> ProcessResult {
        guard config.kind == .ssh else {
            throw RunnerError.configuration(String(localized: "Remote commands need an ssh node"))
        }
        guard master != nil, masterExit == nil else {
            throw RunnerError.network(String(localized: "Node is not connected"))
        }
        return try await remote(sshCommand, script, timeout: timeout)
    }

    // MARK: - loop

    private func log(_ message: String) {
        env.log.log("node:\(config.id)", message)
    }

    private func setStatus(_ phase: NodePhase, _ message: String? = nil, retryAt: Date? = nil) {
        let changed = phase != status.phase
        status = NodeStatus(phase: phase, message: message, since: changed ? Date() : status.since, retryAt: retryAt)
        emit(.status(status))
        if changed { log("\(phase.rawValue)\(message.map { ": \($0)" } ?? "")") }
    }

    private func runLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            let began = Date()
            var terminal = false
            do {
                try await runSession()
                if Task.isCancelled { break }
                setStatus(.offline, String(localized: "Connection closed"))
            } catch is CancellationError {
                break
            } catch let e as RunnerError {
                if Task.isCancelled { break }
                terminal = e.isTerminal
                setStatus(terminal ? .authFailed : .offline, e.description)
            } catch {
                if Task.isCancelled { break }
                setStatus(.offline, "\(error)")
            }
            await teardown()
            if Task.isCancelled { break }
            if terminal {
                await waitForWake(timeout: nil)
                attempt = 0
                continue
            }
            if Date().timeIntervalSince(began) > 60 { attempt = 0 }
            let delay = min(30.0, pow(2.0, Double(attempt)))
            attempt += 1
            setStatus(.offline, status.message, retryAt: Date().addingTimeInterval(delay))
            await waitForWake(timeout: delay)
        }
    }

    private func waitForWake(timeout: Double?) async {
        wakeRequested = false
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while !Task.isCancelled && !wakeRequested {
            if let deadline, Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        wakeRequested = false
    }

    private func teardown() async {
        stream?.terminate(grace: 1)
        stream = nil
        if let token = askToken {
            env.broker?.unregister(token)
            askToken = nil
        }
        if let m = master {
            if m.isRunning {
                _ = try? await ProcessRunner.run(env.sshPath, sshCommand.controlArguments("exit"), timeout: 3)
            }
            m.terminate(grace: 1)
        }
        master = nil
        masterExit = nil
        try? FileManager.default.removeItem(atPath: controlPath)
    }

    private func runSession() async throws {
        switch config.kind {
        case .demo: try await runDemo()
        case .local: try await runLocal()
        case .ssh: try await runSSH()
        }
    }

    // MARK: - local / demo

    private func runLocal() async throws {
        setStatus(.starting)
        guard let agent = env.agentBinary else {
            throw RunnerError.configuration(String(localized: "rpu-agent-mac helper not found"))
        }
        let p = ManagedProcess(executable: agent, arguments: ["--interval", "\(config.interval)"])
        stream = p
        try await consume(try p.start(), process: p)
    }

    private func runDemo() async throws {
        var gen = DemoGenerator(profile: DemoGenerator.Profile(rawValue: config.demoProfile ?? "") ?? .linuxGPU,
                                name: config.name)
        setStatus(.starting)
        emit(.hello(gen.hello(interval: config.interval)))
        setStatus(.online)
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: UInt64(config.interval * 1_000_000_000))
            emit(.sample(gen.sample(at: Date())))
        }
    }

    // MARK: - ssh

    private var controlPath: String { env.paths.controlPath(for: config.id) }

    private var sshCommand: SSHCommand {
        SSHCommand(config: config, controlPath: controlPath, sshPath: env.sshPath)
    }

    private func runSSH() async throws {
        guard !config.target.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RunnerError.configuration(String(localized: "No ssh target configured"))
        }
        setStatus(.connecting)
        let cmd = sshCommand
        try await startMaster(cmd)

        setStatus(.probing)
        let probe = try await remote(cmd, RemoteScripts.probe, timeout: 20)
        guard probe.status == 0, let info = ProbeResult.parse(probe.stdout) else {
            throw RunnerError.remote("probe failed: \(probe.errorText.isEmpty ? probe.output : probe.errorText)")
        }
        log("probe: \(info.os) \(info.arch) python=\(info.python ?? "-") macOS=\(info.macOSVersion ?? "-")")

        switch info.os {
        case "Linux":
            guard let python = info.python else {
                throw RunnerError.unsupported(String(localized: "python3 not found on the remote host"))
            }
            setStatus(.starting)
            let p = ManagedProcess(executable: env.sshPath,
                                   arguments: cmd.clientArguments(RemoteScripts.linuxCollector(python: python, interval: config.interval)))
            stream = p
            try await consume(try p.start(stdin: Data(env.collectorScript.utf8)), process: p)
        case "Darwin":
            guard info.arch == "arm64" else {
                throw RunnerError.unsupported(String(localized: "Only Apple Silicon Macs are supported"))
            }
            let hash = try await ensureAgent(cmd)
            setStatus(.starting)
            let p = ManagedProcess(executable: env.sshPath,
                                   arguments: cmd.clientArguments(RemoteScripts.agentStream(hash: hash, interval: config.interval)))
            stream = p
            try await consume(try p.start(), process: p)
        default:
            throw RunnerError.unsupported("unsupported OS: \(info.os)")
        }
    }

    private func remote(_ cmd: SSHCommand, _ script: String, stdin: Data? = nil, timeout: Double) async throws -> ProcessResult {
        try await ProcessRunner.run(env.sshPath, cmd.clientArguments(script), stdin: stdin, timeout: timeout)
    }

    private func startMaster(_ cmd: SSHCommand) async throws {
        try env.paths.ensureDirectories()
        if FileManager.default.fileExists(atPath: controlPath) {
            // A master left behind by a previous (crashed) instance: ask it to exit.
            _ = try? await ProcessRunner.run(env.sshPath, cmd.controlArguments("exit"), timeout: 3)
            try? FileManager.default.removeItem(atPath: controlPath)
        }

        var environment = ProcessInfo.processInfo.environment
        if cmd.auth == .password {
            guard let broker = env.broker, let helper = env.askpassHelper else {
                throw RunnerError.configuration(String(localized: "Password login needs the rpu-askpass helper"))
            }
            guard env.secrets.hasPassword(for: config.id) else {
                throw RunnerError.authFailed(String(localized: "No password saved for this node"))
            }
            let token = broker.register(AskpassBroker.passwordHandler(nodeID: config.id, secrets: env.secrets))
            askToken = token
            environment["SSH_ASKPASS"] = helper
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
            environment["RPU_ASKPASS_SOCK"] = broker.socketPath
            environment["RPU_ASKPASS_TOKEN"] = token
        }

        let m = ManagedProcess(executable: env.sshPath, arguments: cmd.masterArguments(), environment: environment)
        master = m
        masterExit = nil
        let events = try m.start(holdStdinOpen: true)
        Task { [weak self] in
            for await ev in events {
                if case .exit(let code) = ev { await self?.masterDidExit(code) }
            }
        }

        let deadline = Date().addingTimeInterval(Double(cmd.connectTimeout) + 35)
        while Date() < deadline {
            try Task.checkCancellation()
            if let code = masterExit {
                throw RunnerError.classify(sshStderr: m.stderrTail, status: code)
            }
            if FileManager.default.fileExists(atPath: controlPath) {
                let check = try await ProcessRunner.run(env.sshPath, cmd.controlArguments("check"), timeout: 5)
                if check.status == 0 {
                    if let token = askToken {
                        env.broker?.unregister(token) // authenticated; no more prompts expected
                        askToken = nil
                    }
                    return
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw RunnerError.timeout(String(localized: "ssh connection timed out"))
    }

    private func masterDidExit(_ code: Int32) {
        masterExit = code
        if let s = master?.stderrTail.last { log("ssh master exited (\(code)): \(s)") }
    }

    /// Makes sure the remote Mac has this exact agent build; returns its short hash.
    /// Uploads `rpu-agent-mac.gz` (made by scripts/mac.sh) when present next to the
    /// binary — slow links (≈15 KB/s seen over a relayed VPN link) make size matter.
    private func ensureAgent(_ cmd: SSHCommand) async throws -> String {
        guard let agent = env.agentBinary, let full = Hashing.sha256Hex(fileAt: agent) else {
            throw RunnerError.configuration(String(localized: "rpu-agent-mac helper not found"))
        }
        let hash = String(full.prefix(16))
        setStatus(.deploying)
        let check = try await remote(cmd, RemoteScripts.agentCheck(hash: hash, sha256: full), timeout: 30)
        if check.status == 0, check.stdout.contains(where: { $0.hasPrefix("rpu-agent-mac ") }) {
            return hash
        }
        var attempts: [(path: String, gzipped: Bool)] = []
        if let gz = env.agentGzip { attempts.append((gz, true)) }
        attempts.append((agent, false))
        var lastError = ""
        for attempt in attempts {
            guard let payload = FileManager.default.contents(atPath: attempt.path) else { continue }
            log("uploading agent \(hash) (\(payload.count) bytes\(attempt.gzipped ? ", gzip" : ""))")
            setStatus(.deploying, String(localized: "Uploading agent") + " (\(payload.count / 1024) KB)")
            // Budget ~4 KB/s worst case, at least 2 minutes.
            let timeout = max(120, Double(payload.count) / 4096)
            let upload = try await remote(cmd, RemoteScripts.agentUpload(hash: hash, sha256: full, gzipped: attempt.gzipped),
                                          stdin: payload, timeout: timeout)
            if upload.status == 0, upload.stdout.contains(where: { $0.hasPrefix("rpu-agent-mac ") }) {
                return hash
            }
            lastError = upload.errorText.isEmpty ? upload.output : upload.errorText
            // A stale .gz fails the checksum; fall back to the raw binary.
            guard attempt.gzipped, lastError.contains("checksum mismatch") else { break }
        }
        throw RunnerError.remote("agent upload failed: \(lastError)")
    }

    // MARK: - streaming

    private func consume(_ events: AsyncStream<ProcessEvent>, process: ManagedProcess) async throws {
        lastSampleAt = Date()
        let interval = max(0.2, config.interval)
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.checkStale(interval: interval, process: process)
            }
        }
        defer { watchdog.cancel() }

        var gotHello = false
        for await ev in events {
            switch ev {
            case .stdout(let line):
                guard let msg = AgentMessage.decode(line: line, decoder: decoder) else { continue }
                switch msg {
                case .hello(let h):
                    gotHello = true
                    lastSampleAt = Date()
                    emit(.hello(h))
                    setStatus(.online)
                case .sample(let s):
                    lastSampleAt = Date()
                    if status.phase != .online { setStatus(.online) }
                    emit(.sample(s))
                case .error(let e):
                    log("collector: \(e.msg)")
                    emit(.agentError(e.msg))
                case .unknown:
                    break
                }
            case .stderr(let line):
                log("stderr: \(line)")
            case .exit(let code):
                let tail = process.stderrTail.suffix(3).joined(separator: " | ")
                if config.kind == .ssh, let m = master, !m.isRunning {
                    // The ssh master died: report why the connection went away.
                    let reason = RunnerError.classify(sshStderr: m.stderrTail, status: code)
                    if gotHello, case .remote = reason { throw RunnerError.network(String(localized: "Connection lost")) }
                    throw reason
                }
                throw RunnerError.remote("collector exited (\(code))" + (tail.isEmpty ? "" : ": \(tail)"))
            }
        }
    }

    private func checkStale(interval: Double, process: ManagedProcess) {
        let age = Date().timeIntervalSince(lastSampleAt)
        if age > max(20, 10 * interval) {
            log("no data for \(Int(age))s; restarting stream")
            process.terminate(grace: 1)
        } else if age > 3 * interval + 2, status.phase == .online {
            setStatus(.stale, String(localized: "No recent data"))
        }
    }
}
