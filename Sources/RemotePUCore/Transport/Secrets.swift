import Foundation
import RPUIPC
import Security

public protocol SecretStore: Sendable {
    func password(for nodeID: String) -> String?
    func hasPassword(for nodeID: String) -> Bool
}

/// macOS login keychain, generic password items (service = "RemotePU.ssh", account = node id).
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "RemotePU.ssh") { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Attribute-only lookup: never triggers a keychain access prompt.
    public func exists(account: String) -> Bool {
        var q = base(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    public func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "RemotePU ssh password (\(account))"
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw ControlError("keychain add failed (\(s))") }
        } else if status != errSecSuccess {
            throw ControlError("keychain update failed (\(status))")
        }
    }

    public func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}

/// In-memory secrets (session only) layered over the keychain. Values read from the
/// keychain are cached so ad-hoc–signed rebuilds prompt at most once per launch.
public final class LayeredSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var memory: [String: String] = [:]
    private let keychain: KeychainStore?

    public init(keychain: KeychainStore? = KeychainStore()) {
        self.keychain = keychain
    }

    public func password(for nodeID: String) -> String? {
        lock.lock()
        if let v = memory[nodeID] {
            lock.unlock()
            return v
        }
        lock.unlock()
        guard let v = keychain?.read(account: nodeID) else { return nil }
        lock.lock()
        memory[nodeID] = v
        lock.unlock()
        return v
    }

    public func hasPassword(for nodeID: String) -> Bool {
        lock.lock()
        let inMemory = memory[nodeID] != nil
        lock.unlock()
        return inMemory || (keychain?.exists(account: nodeID) ?? false)
    }

    /// `persist: false` keeps the secret only for this process (used by tests/rpuctl).
    public func setPassword(_ value: String?, for nodeID: String, persist: Bool) throws {
        lock.lock()
        memory[nodeID] = value
        lock.unlock()
        guard persist, let keychain else { return }
        if let value { try keychain.write(value, account: nodeID) } else { keychain.delete(account: nodeID) }
    }
}

/// Answers SSH_ASKPASS requests from rpu-askpass over a private Unix socket.
/// Each ssh master gets a one-time token mapping to a handler for its node.
public final class AskpassBroker: @unchecked Sendable {
    public typealias Handler = @Sendable (String) -> String?

    public let socketPath: String
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var server: UnixSocketServer?

    public init(socketPath: String) throws {
        self.socketPath = socketPath
        let server = UnixSocketServer(path: socketPath) { [weak self] line in
            self?.handle(line) ?? #"{"ok":false}"#
        }
        try server.start()
        self.server = server
    }

    deinit { server?.stop() }

    public func register(_ handler: @escaping Handler) -> String {
        let token = Hashing.randomToken()
        lock.lock()
        handlers[token] = handler
        lock.unlock()
        return token
    }

    public func unregister(_ token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    private func handle(_ line: String) -> String {
        let reply: AskpassReply
        if let req = try? JSONDecoder().decode(AskpassRequest.self, from: Data(line.utf8)) {
            lock.lock()
            let handler = handlers[req.token]
            lock.unlock()
            if let secret = handler?(req.prompt) {
                reply = AskpassReply(ok: true, secret: secret)
            } else {
                RPULog.shared.log("askpass", "declined prompt: \(req.prompt)")
                reply = AskpassReply(ok: false)
            }
        } else {
            reply = AskpassReply(ok: false)
        }
        return (try? String(decoding: JSONEncoder().encode(reply), as: UTF8.self)) ?? #"{"ok":false}"#
    }

    /// Standard prompt policy: password / keyboard-interactive prompts get the node's
    /// password; anything else (OTP, host-key questions) is declined.
    public static func passwordHandler(nodeID: String, secrets: SecretStore) -> Handler {
        { prompt in
            let p = prompt.lowercased()
            guard p.contains("password") || p.contains("passwort") || p.contains("密码") else { return nil }
            return secrets.password(for: nodeID)
        }
    }
}
