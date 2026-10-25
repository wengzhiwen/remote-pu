// SSH_ASKPASS helper. ssh runs it with the prompt as argv[1]; it asks the RemotePU
// process that launched ssh (via the Unix socket + one-time token in the environment)
// and prints the secret on stdout. Exit status 1 means "no answer" and ssh gives up.
import Foundation
import RPUIPC

let env = ProcessInfo.processInfo.environment
guard let socketPath = env[AskpassEnv.socket], let token = env[AskpassEnv.token] else {
    FileHandle.standardError.write(Data("rpu-askpass: not launched by RemotePU\n".utf8))
    exit(1)
}

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
do {
    let line = String(decoding: try JSONEncoder().encode(AskpassRequest(token: token, prompt: prompt)), as: UTF8.self)
    let reply = try JSONDecoder().decode(
        AskpassReply.self,
        from: Data(try UnixSocketClient.request(path: socketPath, line: line, timeout: 120).utf8)
    )
    guard reply.ok, let secret = reply.secret else { exit(1) }
    FileHandle.standardOutput.write(Data((secret + "\n").utf8))
    exit(0)
} catch {
    FileHandle.standardError.write(Data("rpu-askpass: \(error)\n".utf8))
    exit(1)
}
