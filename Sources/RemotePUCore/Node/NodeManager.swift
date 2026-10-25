import Foundation

public struct NodeManagerEvent: Sendable {
    public let nodeID: String
    public let event: NodeEvent
}

/// Owns one NodeRunner per enabled node and fans their events into one stream.
public actor NodeManager {
    public nonisolated let events: AsyncStream<NodeManagerEvent>
    private let continuation: AsyncStream<NodeManagerEvent>.Continuation
    private let env: RunnerEnvironment
    private var runners: [String: NodeRunner] = [:]
    private var configs: [String: NodeConfig] = [:]

    public init(env: RunnerEnvironment) {
        self.env = env
        (events, continuation) = AsyncStream<NodeManagerEvent>.makeStream(bufferingPolicy: .bufferingNewest(10_000))
    }

    /// Reconcile running nodes with `nodes`: start new/changed, stop removed/disabled.
    public func apply(_ nodes: [NodeConfig]) async {
        let wanted = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, runner) in runners where wanted[id] != configs[id] || wanted[id]?.enabled == false {
            await runner.stop()
            runners[id] = nil
        }
        for node in nodes {
            configs[node.id] = node
            guard node.enabled else {
                continuation.yield(NodeManagerEvent(nodeID: node.id, event: .status(NodeStatus(phase: .disabled))))
                continue
            }
            guard runners[node.id] == nil else { continue }
            let id = node.id
            let cont = continuation
            let runner = NodeRunner(config: node, env: env) { event in
                cont.yield(NodeManagerEvent(nodeID: id, event: event))
            }
            runners[id] = runner
            await runner.start()
        }
        for id in configs.keys where wanted[id] == nil { configs[id] = nil }
    }

    public func retry(_ id: String) async {
        await runners[id]?.retryNow()
    }

    public func retryAll() async {
        for r in runners.values { await r.retryNow() }
    }

    public func stopAll() async {
        for r in runners.values { await r.stop() }
        runners.removeAll()
    }

    public func status(of id: String) async -> NodeStatus? {
        await runners[id]?.currentStatus()
    }
}
