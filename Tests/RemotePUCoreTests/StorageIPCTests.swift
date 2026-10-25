import Foundation
import RPUIPC
import RPUProtocol
import Testing
@testable import RemotePUCore

func tempDir() -> URL {
    let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("rpu-test-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func sample(ts: Double, cpu: Double, gpuUtil: Double) -> SampleMessage {
    var s = SampleMessage(ts: ts)
    var c = CPUSample()
    c.util = cpu
    c.tempC = 50
    s.cpu = c
    var g = GPUSample(idx: 0)
    g.util = gpuUtil
    g.tempC = 60
    s.gpus = [g]
    return s
}

@Suite struct HistoryTests {
    @Test func bucketsRollupAndQuery() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(path: dir.appendingPathComponent("h.sqlite"))
        let start = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 - 600 // 10 min ago, minute aligned
        for i in 0..<300 { // 5 minutes of 1 s samples
            await store.ingest(nodeID: "n1", sample: sample(ts: start + Double(i), cpu: Double(i % 10), gpuUtil: 50),
                               gpuKeys: [0: "GPU-x"])
        }
        try await store.flush(includeCurrent: true)
        let stats = try await store.stats()
        #expect(stats["node_5s"] == 60)
        #expect(stats["gpu_5s"] == 60)

        let pts = try await store.query(nodeID: "n1", metric: .node(.cpuUtil),
                                        from: Date(timeIntervalSince1970: start), to: Date(timeIntervalSince1970: start + 300),
                                        maxPoints: 1000)
        #expect(pts.count == 60)
        #expect(abs((pts.first?.avg ?? 0) - 2.0) < 0.001) // mean of 0…4
        #expect(pts.first?.max == 4)

        let gpu = try await store.query(nodeID: "n1", metric: .gpu(key: "GPU-x", .util),
                                        from: Date(timeIntervalSince1970: start), to: Date(timeIntervalSince1970: start + 300))
        #expect(gpu.allSatisfy { $0.avg == 50 })

        try await store.rollup(now: Date(timeIntervalSince1970: start + 600))
        #expect(try await store.stats()["node_1m"] == 5)

        // Downsampling: ask for at most 10 points over 5 minutes → 30 s buckets.
        let coarse = try await store.query(nodeID: "n1", metric: .node(.cpuUtil),
                                           from: Date(timeIntervalSince1970: start), to: Date(timeIntervalSince1970: start + 300),
                                           maxPoints: 10)
        #expect(coarse.count <= 11)

        try await store.prune(retention: .init(raw5sDays: 0, rollup1mDays: 0), now: Date().addingTimeInterval(1))
        #expect(try await store.stats()["node_5s"] == 0)
    }
}

@Suite struct IPCTests {
    @Test func controlServerRoundTrip() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock").path
        let server = ControlServer(path: path) { req in
            switch req.cmd {
            case "echo": return .object(req.args ?? [:])
            case "fail": throw ControlError("nope")
            default: throw ControlError("unknown command \(req.cmd)")
            }
        }
        try server.start()
        defer { server.stop() }
        let ok = try ControlClient.send(path: path, request: ControlRequest(id: "1", cmd: "echo", args: ["a": 1, "b": "x"]))
        #expect(ok.ok)
        #expect(ok.id == "1")
        #expect(ok.result?["b"]?.stringValue == "x")
        let bad = try ControlClient.send(path: path, request: ControlRequest(cmd: "fail"))
        #expect(!bad.ok)
        #expect(bad.error == "nope")
    }

    @Test func askpassBrokerAnswersOnlyPasswordPrompts() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = LayeredSecretStore(keychain: nil)
        try secrets.setPassword("s3cret", for: "mac-b", persist: false)
        let broker = try AskpassBroker(socketPath: dir.appendingPathComponent("a.sock").path)
        let token = broker.register(AskpassBroker.passwordHandler(nodeID: "mac-b", secrets: secrets))

        func ask(_ prompt: String, token: String) throws -> AskpassReply {
            let line = String(decoding: try JSONEncoder().encode(AskpassRequest(token: token, prompt: prompt)), as: UTF8.self)
            return try JSONDecoder().decode(AskpassReply.self, from: Data(try UnixSocketClient.request(path: broker.socketPath, line: line).utf8))
        }
        #expect(try ask("(user@mac-b) Password:", token: token).secret == "s3cret")
        #expect(try ask("Verification code:", token: token).ok == false)
        #expect(try ask("Password:", token: "wrong").ok == false)
        broker.unregister(token)
        #expect(try ask("Password:", token: token).ok == false)
    }

    @Test func jsonValueBasics() throws {
        let v: JSONValue = ["n": 3, "f": 1.5, "s": "x", "b": true, "a": [1, 2], "z": nil]
        let back = try JSONDecoder().decode(JSONValue.self, from: Data(v.compactJSONString().utf8))
        #expect(back == v)
        #expect(v["n"]?.intValue == 3)
        #expect(JSONValue.string("true").boolValue == true)
    }

    @Test func managedProcessStreamsLines() async throws {
        let p = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "echo one; echo two 1>&2; printf three; exit 3"])
        var out: [String] = []
        var err: [String] = []
        var code: Int32 = -1
        for await ev in try p.start() {
            switch ev {
            case .stdout(let l): out.append(l)
            case .stderr(let l): err.append(l)
            case .exit(let c): code = c
            }
        }
        #expect(out == ["one", "three"])
        #expect(err == ["two"])
        #expect(code == 3)

        let r = try await ProcessRunner.run("/bin/cat", [], stdin: Data("hello\nworld\n".utf8), timeout: 5)
        #expect(r.stdout == ["hello", "world"])
        #expect(r.status == 0)
    }
}
