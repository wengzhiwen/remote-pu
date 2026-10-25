import Foundation
import RPUProtocol

/// Persistent history: 5 s buckets (avg + max of 1 s samples) and 1 min rollups.
///
///   node_5s / node_1m  (node, ts, <metric>, <metric>_max …)          — NodeMetric columns
///   gpu_5s  / gpu_1m   (node, gpu, ts, <metric>, <metric>_max …)     — GPUMetric columns
///
/// `ts` is the bucket start in Unix milliseconds.
public actor HistoryStore {
    public struct Retention: Sendable, Equatable {
        public var raw5sDays: Double
        public var rollup1mDays: Double

        public init(raw5sDays: Double = 7, rollup1mDays: Double = 90) {
            self.raw5sDays = raw5sDays
            self.rollup1mDays = rollup1mDays
        }
    }

    public static let bucketMs: Int64 = 5_000
    public static let rollupMs: Int64 = 60_000

    private let db: SQLiteDB
    private var nodeAcc: [String: Accumulator] = [:]
    private var gpuAcc: [String: Accumulator] = [:] // key: node \u{1} gpu
    private var pendingNode: [(node: String, bucket: Int64, values: [Double?])] = []
    private var pendingGPU: [(node: String, gpu: String, bucket: Int64, values: [Double?])] = []

    private static let nodeColumns = NodeMetric.allCases.map(\.rawValue)
    private static let gpuColumns = GPUMetric.allCases.map(\.rawValue)

    /// Running avg/max for one bucket; `values` is [avg…, max…] when finalized.
    struct Accumulator {
        var bucket: Int64
        var sums: [Double]
        var counts: [Int]
        var maxes: [Double]

        init(bucket: Int64, width: Int) {
            self.bucket = bucket
            sums = Array(repeating: 0, count: width)
            counts = Array(repeating: 0, count: width)
            maxes = Array(repeating: -.infinity, count: width)
        }

        mutating func add(_ values: [Double?]) {
            for (i, v) in values.enumerated() {
                guard let v, v.isFinite else { continue }
                sums[i] += v
                counts[i] += 1
                maxes[i] = Swift.max(maxes[i], v)
            }
        }

        var finalized: [Double?] {
            let avgs: [Double?] = sums.indices.map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : nil }
            let mx: [Double?] = maxes.indices.map { counts[$0] > 0 ? maxes[$0] : nil }
            return avgs + mx
        }
    }

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: path.path)
        try Self.createSchema(db)
    }

    private static func columnsDDL(_ cols: [String]) -> String {
        (cols.map { "\($0) REAL" } + cols.map { "\($0)_max REAL" }).joined(separator: ", ")
    }

    private static func createSchema(_ db: SQLiteDB) throws {
        let n = columnsDDL(nodeColumns)
        let g = columnsDDL(gpuColumns)
        for table in ["node_5s", "node_1m"] {
            try db.exec("CREATE TABLE IF NOT EXISTS \(table) (node TEXT NOT NULL, ts INTEGER NOT NULL, \(n), PRIMARY KEY (node, ts)) WITHOUT ROWID;")
        }
        for table in ["gpu_5s", "gpu_1m"] {
            try db.exec("CREATE TABLE IF NOT EXISTS \(table) (node TEXT NOT NULL, gpu TEXT NOT NULL, ts INTEGER NOT NULL, \(g), PRIMARY KEY (node, gpu, ts)) WITHOUT ROWID;")
        }
        try db.exec("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);")
    }

    // MARK: - ingest

    public func ingest(nodeID: String, sample: SampleMessage, gpuKeys: [Int: String]) {
        let ms = Int64(sample.ts * 1000)
        let bucket = ms - ms % Self.bucketMs

        let nodeValues = NodeMetric.allCases.map { $0.value(sample) }
        if var acc = nodeAcc[nodeID], acc.bucket == bucket {
            acc.add(nodeValues)
            nodeAcc[nodeID] = acc
        } else {
            if let old = nodeAcc[nodeID], old.bucket < bucket {
                pendingNode.append((nodeID, old.bucket, old.finalized))
            }
            var acc = Accumulator(bucket: bucket, width: nodeValues.count)
            acc.add(nodeValues)
            nodeAcc[nodeID] = acc
        }

        for g in sample.gpus ?? [] {
            let key = gpuKeys[g.idx] ?? "idx\(g.idx)"
            let accKey = nodeID + "\u{1}" + key
            let values = GPUMetric.allCases.map { $0.value(g) }
            if var acc = gpuAcc[accKey], acc.bucket == bucket {
                acc.add(values)
                gpuAcc[accKey] = acc
            } else {
                if let old = gpuAcc[accKey], old.bucket < bucket {
                    pendingGPU.append((nodeID, key, old.bucket, old.finalized))
                }
                var acc = Accumulator(bucket: bucket, width: values.count)
                acc.add(values)
                gpuAcc[accKey] = acc
            }
        }
    }

    /// Write finished buckets. `includeCurrent` also writes the in-progress bucket (shutdown).
    public func flush(includeCurrent: Bool = false) throws {
        if includeCurrent {
            for (node, acc) in nodeAcc { pendingNode.append((node, acc.bucket, acc.finalized)) }
            for (k, acc) in gpuAcc {
                let parts = k.split(separator: "\u{1}", maxSplits: 1).map(String.init)
                if parts.count == 2 { pendingGPU.append((parts[0], parts[1], acc.bucket, acc.finalized)) }
            }
            nodeAcc.removeAll()
            gpuAcc.removeAll()
        }
        guard !pendingNode.isEmpty || !pendingGPU.isEmpty else { return }
        let nodeRows = pendingNode
        let gpuRows = pendingGPU
        pendingNode.removeAll()
        pendingGPU.removeAll()

        let nCols = Self.nodeColumns + Self.nodeColumns.map { $0 + "_max" }
        let gCols = Self.gpuColumns + Self.gpuColumns.map { $0 + "_max" }
        let nodeSQL = "INSERT OR REPLACE INTO node_5s (node, ts, \(nCols.joined(separator: ", "))) VALUES (?, ?, \(Array(repeating: "?", count: nCols.count).joined(separator: ", ")))"
        let gpuSQL = "INSERT OR REPLACE INTO gpu_5s (node, gpu, ts, \(gCols.joined(separator: ", "))) VALUES (?, ?, ?, \(Array(repeating: "?", count: gCols.count).joined(separator: ", ")))"
        try db.transaction {
            let ns = try db.prepare(nodeSQL)
            for row in nodeRows {
                ns.reset()
                ns.bind(1, row.node)
                ns.bind(2, row.bucket)
                for (i, v) in row.values.enumerated() { ns.bind(Int32(3 + i), v) }
                try ns.step()
            }
            let gs = try db.prepare(gpuSQL)
            for row in gpuRows {
                gs.reset()
                gs.bind(1, row.node)
                gs.bind(2, row.gpu)
                gs.bind(3, row.bucket)
                for (i, v) in row.values.enumerated() { gs.bind(Int32(4 + i), v) }
                try gs.step()
            }
        }
    }

    // MARK: - rollup / retention

    private func meta(_ key: String) throws -> String? {
        let s = try db.prepare("SELECT v FROM meta WHERE k = ?")
        s.bind(1, key)
        return try s.step() ? s.text(0) : nil
    }

    private func setMeta(_ key: String, _ value: String) throws {
        let s = try db.prepare("INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)")
        s.bind(1, key)
        s.bind(2, value)
        try s.step()
    }

    /// Aggregate complete minutes from the 5 s tables into the 1 min tables.
    public func rollup(now: Date = Date()) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Leave room for buckets still being accumulated/flushed.
        let until = (nowMs - 2 * Self.rollupMs) / Self.rollupMs * Self.rollupMs
        var from = Int64(try meta("rollup_until") ?? "") ?? 0
        if from == 0 {
            let s = try db.prepare("SELECT MIN(ts) FROM node_5s")
            if try s.step(), let minTs = s.double(0) { from = Int64(minTs) / Self.rollupMs * Self.rollupMs }
        }
        guard from > 0, from < until else { return }

        func rollupSQL(_ src: String, _ dst: String, _ cols: [String], keys: String) -> String {
            let avgs = cols.map { "AVG(\($0))" }
            let maxes = cols.map { "MAX(\($0)_max)" }
            let all = cols + cols.map { $0 + "_max" }
            return "INSERT OR REPLACE INTO \(dst) (\(keys), ts, \(all.joined(separator: ", "))) "
                + "SELECT \(keys), (ts / \(Self.rollupMs)) * \(Self.rollupMs) AS b, \((avgs + maxes).joined(separator: ", ")) "
                + "FROM \(src) WHERE ts >= ? AND ts < ? GROUP BY \(keys), b"
        }
        try db.transaction {
            for (sql) in [rollupSQL("node_5s", "node_1m", Self.nodeColumns, keys: "node"),
                          rollupSQL("gpu_5s", "gpu_1m", Self.gpuColumns, keys: "node, gpu")] {
                let s = try db.prepare(sql)
                s.bind(1, from)
                s.bind(2, until)
                try s.step()
            }
            try setMeta("rollup_until", String(until))
        }
    }

    public func prune(retention: Retention, now: Date = Date()) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let raw = nowMs - Int64(retention.raw5sDays * 86_400_000)
        let roll = nowMs - Int64(retention.rollup1mDays * 86_400_000)
        try db.transaction {
            for (table, cutoff) in [("node_5s", raw), ("gpu_5s", raw), ("node_1m", roll), ("gpu_1m", roll)] {
                let s = try db.prepare("DELETE FROM \(table) WHERE ts < ?")
                s.bind(1, cutoff)
                try s.step()
            }
        }
    }

    /// flush + rollup + prune; call periodically.
    public func maintenance(retention: Retention) {
        do {
            try flush()
            try rollup()
            try prune(retention: retention)
        } catch {
            RPULog.shared.log("history", "maintenance failed: \(error)")
        }
    }

    // MARK: - query

    /// Downsampled series between `from` and `to` (at most ~`maxPoints` points).
    public func query(nodeID: String, metric: MetricRef, from: Date, to: Date, maxPoints: Int = 600,
                      retention: Retention = Retention(), now: Date = Date()) throws -> [SeriesPoint] {
        try? flush()
        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)
        guard toMs > fromMs else { return [] }
        let rawStart = Int64(now.timeIntervalSince1970 * 1000) - Int64(retention.raw5sDays * 86_400_000)
        let useRaw = fromMs >= rawStart
        let resolution = useRaw ? Self.bucketMs : Self.rollupMs
        let span = toMs - fromMs
        let bucket = max(resolution, (span / Int64(max(1, maxPoints)) + resolution - 1) / resolution * resolution)

        let column: String
        let table: String
        var gpuKey: String?
        switch metric {
        case .node(let m):
            column = m.rawValue
            table = useRaw ? "node_5s" : "node_1m"
        case .gpu(let key, let m):
            column = m.rawValue
            table = useRaw ? "gpu_5s" : "gpu_1m"
            gpuKey = key
        }
        let gpuFilter = gpuKey == nil ? "" : " AND gpu = ?"
        let sql = "SELECT (ts / \(bucket)) * \(bucket) AS b, AVG(\(column)), MAX(\(column)_max) FROM \(table) "
            + "WHERE node = ?\(gpuFilter) AND ts >= ? AND ts <= ? AND \(column) IS NOT NULL GROUP BY b ORDER BY b"
        let s = try db.prepare(sql)
        var i: Int32 = 1
        s.bind(i, nodeID); i += 1
        if let gpuKey { s.bind(i, gpuKey); i += 1 }
        s.bind(i, fromMs); i += 1
        s.bind(i, toMs)
        var points: [SeriesPoint] = []
        while try s.step() {
            guard let avg = s.double(1) else { continue }
            let t = Date(timeIntervalSince1970: Double(s.int64(0)) / 1000)
            points.append(SeriesPoint(t: t, avg: avg, max: s.double(2) ?? avg))
        }
        return points
    }

    /// Row counts per table (diagnostics for the control API).
    public func stats() throws -> [String: Int] {
        var out: [String: Int] = [:]
        for table in ["node_5s", "gpu_5s", "node_1m", "gpu_1m"] {
            let s = try db.prepare("SELECT COUNT(*) FROM \(table)")
            if try s.step() { out[table] = Int(s.int64(0)) }
        }
        return out
    }
}
