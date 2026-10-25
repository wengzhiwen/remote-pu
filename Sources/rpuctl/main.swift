// rpuctl — command-line client for the RemotePU control API (see docs/CONTROL_API.md).
//
//   rpuctl [--socket PATH] [--timeout SEC] <cmd> [key=value ...] [key:=<json> ...]
//
//   rpuctl help
//   rpuctl state
//   rpuctl nodes.add name=mac-b target=user@mac-b auth=password
//   rpuctl nodes.setPassword id=mac-b password=... persist=false
//   rpuctl nodes.wait id=mac-b phase=online timeout=60
//   rpuctl ui.open window=main && rpuctl ui.select node=mac-b
//   rpuctl ui.screenshot window=main path=/tmp/rpu-main.png
import Foundation
import RPUIPC

func usage() -> Never {
    let text = """
    usage: rpuctl [--socket PATH] [--timeout SEC] <cmd> [key=value ...] [key:=json ...]
      value parsing: true/false/null/numbers are typed; use key:=<json> for raw JSON
      default socket: $RPU_CONTROL_SOCKET or ~/Library/Application Support/RemotePU/control.sock
      run `rpuctl help` against a running app for the command list
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

func parseValue(_ raw: String) -> JSONValue {
    switch raw {
    case "true": return .bool(true)
    case "false": return .bool(false)
    case "null": return .null
    default:
        if let d = Double(raw), raw.first.map({ $0.isNumber || $0 == "-" }) == true { return .number(d) }
        return .string(raw)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment
var socketPath = env["RPU_CONTROL_SOCKET"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/RemotePU/control.sock")
var timeout = 60.0

while let first = args.first, first.hasPrefix("--") {
    args.removeFirst()
    switch first {
    case "--socket":
        guard !args.isEmpty else { usage() }
        socketPath = args.removeFirst()
    case "--timeout":
        guard !args.isEmpty, let t = Double(args.removeFirst()) else { usage() }
        timeout = t
    case "--help", "-h":
        usage()
    default:
        usage()
    }
}

guard !args.isEmpty else { usage() }
let cmd = args.removeFirst()
var cmdArgs: [String: JSONValue] = [:]
for item in args {
    if let r = item.range(of: ":=") {
        let key = String(item[..<r.lowerBound])
        let json = String(item[r.upperBound...])
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
            FileHandle.standardError.write(Data("rpuctl: invalid JSON for \(key)\n".utf8))
            exit(2)
        }
        cmdArgs[key] = v
    } else if let eq = item.firstIndex(of: "=") {
        cmdArgs[String(item[..<eq])] = parseValue(String(item[item.index(after: eq)...]))
    } else {
        FileHandle.standardError.write(Data("rpuctl: expected key=value, got \(item)\n".utf8))
        exit(2)
    }
}

do {
    let response = try ControlClient.send(
        path: socketPath,
        request: ControlRequest(id: UUID().uuidString, cmd: cmd, args: cmdArgs.isEmpty ? nil : cmdArgs),
        timeout: timeout
    )
    if response.ok {
        let result = response.result ?? .null
        if case .string(let s) = result { print(s) } else { print(result.prettyJSONString()) }
        exit(0)
    }
    FileHandle.standardError.write(Data("error: \(response.error ?? "unknown")\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("rpuctl: cannot reach RemotePU at \(socketPath): \(error)\n".utf8))
    exit(3)
}
