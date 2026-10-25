import Foundation

/// Control API envelope (one JSON line each way over a Unix socket).
/// Request:  {"id":"1","cmd":"state","args":{...}}
/// Response: {"id":"1","ok":true,"result":...}  |  {"id":"1","ok":false,"error":"..."}
public struct ControlRequest: Codable, Sendable {
    public var id: String?
    public var cmd: String
    public var args: [String: JSONValue]?

    public init(id: String? = nil, cmd: String, args: [String: JSONValue]? = nil) {
        self.id = id
        self.cmd = cmd
        self.args = args
    }

    public func arg(_ key: String) -> JSONValue? { args?[key] }
    public func string(_ key: String) -> String? { args?[key]?.stringValue }
    public func double(_ key: String) -> Double? { args?[key]?.doubleValue }
    public func int(_ key: String) -> Int? { args?[key]?.intValue }
    public func bool(_ key: String) -> Bool? { args?[key]?.boolValue }
}

public struct ControlResponse: Codable, Sendable {
    public var id: String?
    public var ok: Bool
    public var result: JSONValue?
    public var error: String?

    public init(id: String?, ok: Bool, result: JSONValue? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(_ id: String?, _ result: JSONValue = .null) -> ControlResponse {
        ControlResponse(id: id, ok: true, result: result)
    }

    public static func failure(_ id: String?, _ message: String) -> ControlResponse {
        ControlResponse(id: id, ok: false, error: message)
    }
}

public struct ControlError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Serves ControlRequests on a Unix socket, dispatching to `handler`.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async throws -> JSONValue

    private let server: UnixSocketServer
    public var path: String { server.path }

    public init(path: String, handler: @escaping Handler) {
        server = UnixSocketServer(path: path) { line in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let response: ControlResponse
            do {
                let req = try decoder.decode(ControlRequest.self, from: Data(line.utf8))
                do {
                    response = .success(req.id, try await handler(req))
                } catch {
                    response = .failure(req.id, "\(error)")
                }
            } catch {
                response = .failure(nil, "bad request: \(error)")
            }
            return (try? String(decoding: encoder.encode(response), as: UTF8.self))
                ?? #"{"ok":false,"error":"encoding failure"}"#
        }
    }

    public func start() throws { try server.start() }
    public func stop() { server.stop() }
}

public enum ControlClient {
    public static func send(path: String, request: ControlRequest, timeout: Double = 60) throws -> ControlResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let line = String(decoding: try encoder.encode(request), as: UTF8.self)
        let reply = try UnixSocketClient.request(path: path, line: line, timeout: timeout)
        return try JSONDecoder().decode(ControlResponse.self, from: Data(reply.utf8))
    }
}

/// Askpass helper wire format (rpu-askpass <-> AskpassBroker).
public struct AskpassRequest: Codable, Sendable {
    public var token: String
    public var prompt: String

    public init(token: String, prompt: String) {
        self.token = token
        self.prompt = prompt
    }
}

public struct AskpassReply: Codable, Sendable {
    public var ok: Bool
    public var secret: String?

    public init(ok: Bool, secret: String? = nil) {
        self.ok = ok
        self.secret = secret
    }
}

public enum AskpassEnv {
    public static let socket = "RPU_ASKPASS_SOCK"
    public static let token = "RPU_ASKPASS_TOKEN"
}
