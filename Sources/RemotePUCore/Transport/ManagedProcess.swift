import Darwin
import Foundation

public enum ProcessEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

/// A child process whose stdout/stderr arrive as line events on an AsyncStream.
///
/// The stream finishes after `.exit`. We wait for stdout EOF (bounded) before emitting
/// `.exit`, but never for stderr EOF: a grandchild (e.g. an ssh mux master) may keep
/// stderr open indefinitely.
public final class ManagedProcess: @unchecked Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]?

    private let process = Process()
    private let lock = NSLock()
    private var heldStdin: FileHandle?
    private var outBuffer = Data()
    private var errBuffer = Data()
    private var stderrLines: [String] = []
    private var continuation: AsyncStream<ProcessEvent>.Continuation?
    private let stdoutClosed = DispatchSemaphore(value: 0)
    private var exited = false

    public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    public var isRunning: Bool { process.isRunning }
    public var pid: Int32 { process.processIdentifier }

    /// Last stderr lines (most recent last).
    public var stderrTail: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stderrLines
    }

    /// - Parameter holdStdinOpen: give the child a stdin pipe that stays open until
    ///   `terminate()` or until this process dies (the kernel closes it → EOF). Used
    ///   for ssh masters so they can never outlive the app.
    public func start(stdin: Data? = nil, holdStdinOpen: Bool = false) throws -> AsyncStream<ProcessEvent> {
        let (stream, cont) = AsyncStream<ProcessEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = (stdin == nil && !holdStdinOpen) ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.flush(isError: false, final: true)
                self.stdoutClosed.signal()
            } else {
                self.consume(data, isError: false)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.flush(isError: true, final: true)
            } else {
                self.consume(data, isError: true)
            }
        }
        process.terminationHandler = { [weak self] p in
            self?.handleExit(p.terminationStatus)
        }

        do {
            try process.run()
            ProcessRegistry.shared.add(process.processIdentifier)
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            cont.finish()
            throw error
        }

        if holdStdinOpen, let inPipe {
            heldStdin = inPipe.fileHandleForWriting
        } else if let inPipe, let stdin {
            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                // SIGPIPE is ignored process-wide (see `ignoreSIGPIPE()`), so a dead
                // child surfaces here as a thrown error instead of killing us.
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }
        return stream
    }

    /// SIGTERM, then SIGKILL after `grace` seconds.
    public func terminate(grace: Double = 2) {
        try? heldStdin?.close()
        heldStdin = nil
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    private func consume(_ data: Data, isError: Bool) {
        lock.lock()
        if isError { errBuffer.append(data) } else { outBuffer.append(data) }
        lock.unlock()
        flush(isError: isError, final: false)
    }

    private func flush(isError: Bool, final: Bool) {
        var lines: [String] = []
        lock.lock()
        var buffer = isError ? errBuffer : outBuffer
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
            lines.append(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        if final, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer = Data()
        }
        if isError {
            errBuffer = buffer
            stderrLines.append(contentsOf: lines.filter { !$0.isEmpty })
            if stderrLines.count > 50 { stderrLines.removeFirst(stderrLines.count - 50) }
        } else {
            outBuffer = buffer
        }
        let cont = exited ? nil : continuation
        lock.unlock()
        for line in lines {
            cont?.yield(isError ? .stderr(line) : .stdout(line))
        }
    }

    private func handleExit(_ status: Int32) {
        ProcessRegistry.shared.remove(process.processIdentifier)
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = stdoutClosed.wait(timeout: .now() + 2)
            usleep(50_000) // let trailing stderr arrive
            flush(isError: true, final: false)
            lock.lock()
            exited = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.yield(.exit(status))
            cont?.finish()
        }
    }
}

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: [String]
    public var stderr: [String]

    public var output: String { stdout.joined(separator: "\n") }
    public var errorText: String { stderr.joined(separator: "\n") }
}

public enum ProcessRunner {
    /// Run to completion (killed after `timeout` seconds) and collect output lines.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           stdin: Data? = nil, timeout: Double = 30) async throws -> ProcessResult {
        let p = ManagedProcess(executable: executable, arguments: arguments, environment: environment)
        let events = try p.start(stdin: stdin)
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { p.terminate(grace: 1) }
        }
        defer { timer.cancel() }
        var result = ProcessResult(status: -1, stdout: [], stderr: [])
        for await ev in events {
            switch ev {
            case .stdout(let l): result.stdout.append(l)
            case .stderr(let l): result.stderr.append(l)
            case .exit(let s): result.status = s
            }
        }
        return result
    }
}

/// Writing to a pipe whose reader died must not kill the app.
public func ignoreSIGPIPE() {
    signal(SIGPIPE, SIG_IGN)
}

/// Every child we started, so the app can SIGTERM them synchronously on quit.
public final class ProcessRegistry: @unchecked Sendable {
    public static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var pids = Set<Int32>()

    func add(_ pid: Int32) {
        lock.lock()
        pids.insert(pid)
        lock.unlock()
    }

    func remove(_ pid: Int32) {
        lock.lock()
        pids.remove(pid)
        lock.unlock()
    }

    public var running: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pids)
    }

    public func terminateAll() {
        for pid in running { kill(pid, SIGTERM) }
    }
}
