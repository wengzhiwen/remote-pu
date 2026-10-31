import Foundation
import Testing
@testable import RemotePUCore

/// AetherSwitch (`mgr`) script building and output parsing. The JSON fixtures
/// mirror the deployed controller's output shape (sanitized mode ids/urls).
@Suite struct AetherSwitchTests {
    @Test func parsesCombinedListAndStatus() throws {
        let out = [
            "",
            AetherScripts.splitMarker,
            """
            [
              {"mode": "vllm-box", "name": "vLLM · Qwen text"},
              {"mode": "webui", "name": "ComfyUI + webui"}
            ]
            """,
            AetherScripts.splitMarker,
            """
            {
              "modes": [
                {"mode": "vllm-box", "unit": "server-mgr-vllm-box.service", "state": "ready",
                 "healthy": true, "accepting_requests": true, "busy": false,
                 "probe": {"healthy": true, "public_url": "http://192.0.2.10:8000"}},
                {"mode": "webui", "state": "stopped", "healthy": false}
              ],
              "operation": {"action": "switch", "target": "vllm-box", "stage": "complete",
                            "in_progress": false, "mode": "vllm-box"},
              "conflicts": [],
              "current_mode": "vllm-box",
              "gpus": {"GPU-11111111-2222-3333-4444-000000000000": {"memory_used_mib": 15, "memory_total_mib": 24467}}
            }
            """,
        ]
        let (modes, status) = try AetherScripts.parse(out)
        #expect(modes.map(\.mode) == ["vllm-box", "webui"])
        #expect(modes[0].name == "vLLM · Qwen text")
        #expect(status.currentMode == "vllm-box")
        #expect(status.modes.count == 2)
        #expect(status.modes[0].probe?.publicUrl == "http://192.0.2.10:8000")
        #expect(status.modes[0].acceptingRequests == true)
        #expect(status.modes[1].healthy == false)
        #expect(status.operation?.inProgress == false)
        #expect(status.operation?.stage == "complete")
        #expect(status.report(for: "webui")?.state == "stopped")
    }

    @Test func toleratesMissingOptionalGroups() throws {
        let out = ["", AetherScripts.splitMarker, "", AetherScripts.splitMarker, #"{"modes": [], "current_mode": null}"#]
        let (modes, status) = try AetherScripts.parse(out)
        #expect(modes.isEmpty)
        #expect(status.currentMode == nil)
        #expect(status.conflicts.isEmpty)
        #expect(status.operation == nil)
    }

    @Test func rejectsTruncatedOutput() {
        #expect((try? AetherScripts.parse(["not json"])) == nil)
        #expect((try? AetherScripts.parse([AetherScripts.splitMarker, "[]"])) == nil)
        #expect((try? AetherScripts.parse(["[]", AetherScripts.splitMarker, "{oops"])) == nil)
    }

    @Test func dirQuoting() {
        #expect(AetherScripts.quotedDir("~") == "\"$HOME\"")
        #expect(AetherScripts.quotedDir("~/server_mgr") == "\"$HOME\"\"/server_mgr\"")
        #expect(AetherScripts.quotedDir("/opt/server mgr") == "\"/opt/server mgr\"")
        #expect(AetherScripts.quotedDir("/a$b\"c`d\\e") == "\"/a\\$b\\\"c\\`d\\\\e\"")
        #expect(AetherScripts.quotedDir(" ~/server_mgr ") == "\"$HOME\"\"/server_mgr\"")
    }

    @Test func scriptsCdIntoTheConfiguredDir() {
        let combined = AetherScripts.statusAndList(dir: "~/server_mgr")
        #expect(combined.hasPrefix("sh -c '"))
        #expect(combined.contains(#"cd "$HOME""/server_mgr" || exit 9"#))
        #expect(combined.contains("./mgr list --json"))
        #expect(combined.contains("exec ./mgr status --json"))
        #expect(combined.contains(AetherScripts.splitMarker))
        let sw = AetherScripts.switchMode(dir: "/opt/mgr", mode: "vllm box")
        #expect(sw.contains(#"cd "/opt/mgr" || exit 9"#))
        #expect(sw.contains("exec ./mgr switch ")) // mode id is single-quoted (and re-quoted inside sh -c)
        #expect(sw.contains("vllm box"))
        #expect(AetherScripts.stop(dir: "/opt/mgr").contains("exec ./mgr stop"))
        #expect(AetherScripts.restartMode(dir: "/opt/mgr", mode: "wan").contains("./mgr restart"))
    }

    @Test func nodeConfigAetherRoundTrip() throws {
        #expect(try JSONDecoder().decode(NodeConfig.self, from: Data(#"{"name":"b","target":"user@b"}"#.utf8)).aetherSwitch == nil)
        let withDir = try JSONDecoder().decode(NodeConfig.self,
                                               from: Data(#"{"name":"b","target":"user@b","aetherSwitch":{"dir":"/opt/mgr"}}"#.utf8))
        #expect(withDir.aetherSwitch?.dir == "/opt/mgr")
        let back = try JSONDecoder().decode(NodeConfig.self, from: try JSONEncoder().encode(withDir))
        #expect(back.aetherSwitch == withDir.aetherSwitch)
    }
}
