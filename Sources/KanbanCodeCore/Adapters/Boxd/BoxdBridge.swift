import Foundation

// MARK: - Wire messages

/// A `kanban` command run inside the machine that must execute on the Mac.
public struct BridgeProxyRequest: Sendable, Equatable {
    public struct Image: Sendable, Equatable {
        public let name: String
        public let data: Data
        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    public let id: String
    public let argv: [String]
    public let cwd: String?
    public let stdin: String?
    public let env: [String: String]
    public let images: [Image]

    public init(id: String, argv: [String], cwd: String? = nil, stdin: String? = nil, env: [String: String] = [:], images: [Image] = []) {
        self.id = id
        self.argv = argv
        self.cwd = cwd
        self.stdin = stdin
        self.env = env
        self.images = images
    }
}

/// What the machine tells the Mac.
public enum BridgeEvent: Sendable, Equatable {
    case hello(agentVersion: String, home: String, vm: String)
    case file(path: String, cwd: String?, offset: Int, data: Data, eof: Bool)
    case removed(path: String)
    case proxy(BridgeProxyRequest)
    case activity(kind: String)
    /// The process behind the bridge ended. No more events follow.
    case disconnected(reason: String)
}

/// A root the machine watches, with optional globs relative to it.
public struct BridgeWatchRoot: Sendable, Equatable {
    public let path: String
    public let globs: [String]
    public init(path: String, globs: [String] = []) {
        self.path = path
        self.globs = globs
    }
}

// MARK: - Channel

/// The byte pipe under a bridge: lines out, lines in. The real one is the
/// stdin and stdout of `boxd machine exec`; tests plug an in-memory pair.
public protocol BridgeChannel: Sendable {
    /// Lines from the machine, without the trailing newline. Ends when the
    /// process ends.
    var lines: AsyncStream<String> { get }
    /// Sends one line to the machine.
    func send(line: String) throws
    /// Ends the process behind the channel.
    func close()
    /// Why the channel ended, once it did.
    func terminationReason() async -> String
}

/// A `BridgeChannel` over `boxd machine exec <vm> -- <argv>`.
public final class ProcessBridgeChannel: BridgeChannel, @unchecked Sendable {
    public let lines: AsyncStream<String>
    private let process: Process
    private let stdinHandle: FileHandle
    private let stderrText = LineCollector()
    private let writeLock = NSLock()
    private var closed = false

    public init(executable: String, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting

        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.lines = stream

        let stderrCollector = stderrText
        Self.readLines(from: stderrPipe.fileHandleForReading) { line in
            stderrCollector.append(line)
        } onEnd: {}

        Self.readLines(from: stdoutPipe.fileHandleForReading) { line in
            continuation.yield(line)
        } onEnd: {
            continuation.finish()
        }

        try process.run()
    }

    public func send(line: String) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed, process.isRunning else { throw BoxdBridgeError.disconnected }
        try stdinHandle.write(contentsOf: Data((line + "\n").utf8))
    }

    public func close() {
        writeLock.lock()
        let wasClosed = closed
        closed = true
        writeLock.unlock()
        guard !wasClosed else { return }
        try? stdinHandle.close()
        if process.isRunning { process.terminate() }
    }

    public func terminationReason() async -> String {
        let status = process.isRunning ? "running" : "exit \(process.terminationStatus)"
        let stderr = stderrText.tail(lines: 5)
        return stderr.isEmpty ? status : "\(status): \(stderr)"
    }

    /// Reads a pipe on its own thread and hands over each complete line.
    /// Runs outside any actor so the blocking read never sits on the
    /// cooperative pool.
    private nonisolated static func readLines(
        from handle: FileHandle,
        onLine: @escaping @Sendable (String) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) {
        let thread = Thread {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let line = String(data: lineData, encoding: .utf8) {
                        onLine(line)
                    }
                }
            }
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                onLine(line)
            }
            try? handle.close()
            onEnd()
        }
        thread.name = "kanban.boxd.bridge.reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(line)
            if lines.count > 50 { lines.removeFirst(lines.count - 50) }
        }

        func tail(lines count: Int) -> String {
            lock.lock(); defer { lock.unlock() }
            return lines.suffix(count).joined(separator: " | ")
        }
    }
}

public enum BoxdBridgeError: Error, LocalizedError, Equatable {
    case disconnected
    case timeout(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .disconnected: "The bridge to the machine is closed"
        case .timeout(let what): "The machine did not answer \(what) in time"
        case .malformed(let what): "The machine sent a message this version cannot read: \(what)"
        }
    }
}

// MARK: - Bridge

/// One live connection to the remote agent of a machine.
///
/// Sends `watch`, `put`, `exec`, `proxy-result` and `ping`; publishes what
/// the machine sends as `events`. One instance stands for one process; the
/// supervisor makes a new one when it reconnects.
public actor BoxdBridge: RemoteCommandRunner {
    public let machineName: String
    public let events: AsyncStream<BridgeEvent>

    /// Home directory reported by `hello`.
    public private(set) var remoteHome: String?
    public private(set) var agentVersion: String?
    public private(set) var connected = false

    private let channel: any BridgeChannel
    private let eventContinuation: AsyncStream<BridgeEvent>.Continuation
    private var pendingExecs: [String: CheckedContinuation<ShellCommand.Result, any Error>] = [:]
    private var pendingPongs: [String: CheckedContinuation<Void, any Error>] = [:]
    private var helloWaiters: [String: CheckedContinuation<Void, any Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var nextId = 0

    public init(machineName: String, channel: any BridgeChannel) {
        self.machineName = machineName
        self.channel = channel
        let (stream, continuation) = AsyncStream<BridgeEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.eventContinuation = continuation
    }

    /// Opens the default bridge: `boxd machine exec <vm> -- node kanban.js remote-agent`.
    public static func spawn(machineName: String, boxdPath: String? = nil, remoteHome: String = "/home/boxd") throws -> BoxdBridge {
        let executable = boxdPath ?? ShellCommand.findExecutable("boxd") ?? "boxd"
        let channel = try ProcessBridgeChannel(
            executable: executable,
            arguments: [
                "machine", "exec", machineName, "--",
                "/usr/local/bin/node", "\(remoteHome)/.kanban-code/cli/dist/kanban.js", "remote-agent",
            ],
            environment: ShellCommand.loginEnvironment
        )
        return BoxdBridge(machineName: machineName, channel: channel)
    }

    /// Starts reading and waits for `hello`.
    public func start(helloTimeout: Duration = .seconds(60)) async throws {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in
            guard let self else { return }
            for await line in self.channel.lines {
                await self.handle(line: line)
            }
            let reason = await self.channel.terminationReason()
            await self.finish(reason: reason)
        }
        guard !connected else { return }
        let id = makeId()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: helloTimeout)
            await self?.timeOut(hello: id)
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            helloWaiters[id] = continuation
        }
    }

    private func makeId() -> String {
        nextId += 1
        return "x\(nextId)"
    }

    private func timeOut(hello id: String) {
        helloWaiters.removeValue(forKey: id)?.resume(throwing: BoxdBridgeError.timeout("hello"))
    }

    private func timeOut(exec id: String, what: String) {
        pendingExecs.removeValue(forKey: id)?.resume(throwing: BoxdBridgeError.timeout(what))
    }

    private func timeOut(ping id: String) {
        pendingPongs.removeValue(forKey: id)?.resume(throwing: BoxdBridgeError.timeout("ping"))
    }

    public func stop() {
        channel.close()
    }

    // MARK: Requests

    public func watch(roots: [BridgeWatchRoot], offsets: [String: Int]) throws {
        try send([
            "type": "watch",
            "roots": roots.map { ["path": $0.path, "globs": $0.globs] },
            "offsets": offsets,
        ])
    }

    public func put(path: String, data: Data, mode: Int?) async throws {
        var message: [String: Any] = ["type": "put", "path": path, "data": data.base64EncodedString()]
        if let mode { message["mode"] = mode }
        try send(message)
    }

    public func remove(path: String) async throws {
        _ = try await exec(["rm", "-f", path], stdin: nil, cwd: nil, timeout: 20)
    }

    public func exec(_ argv: [String], stdin: String?, cwd: String?, timeout: TimeInterval) async throws -> ShellCommand.Result {
        guard connected else { throw BoxdBridgeError.disconnected }
        let id = makeId()
        var message: [String: Any] = ["type": "exec", "id": id, "argv": argv]
        if let stdin { message["stdin"] = stdin }
        if let cwd { message["cwd"] = cwd }
        let what = argv.prefix(2).joined(separator: " ")
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.timeOut(exec: id, what: what)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingExecs[id] = continuation
            do {
                try send(message)
            } catch {
                pendingExecs[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    public func reply(to request: BridgeProxyRequest, stdout: String, stderr: String, code: Int32) throws {
        try send([
            "type": "proxy-result",
            "id": request.id,
            "stdout": stdout,
            "stderr": stderr,
            "code": Int(code),
        ])
    }

    public func ping(timeout: Duration = .seconds(15)) async throws {
        guard connected else { throw BoxdBridgeError.disconnected }
        let id = makeId()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timeOut(ping: id)
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pendingPongs[id] = continuation
            do {
                try send(["type": "ping"])
            } catch {
                pendingPongs[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    public func isConnected() async -> Bool { connected }

    // MARK: Wire

    private func send(_ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else { throw BoxdBridgeError.malformed("outgoing") }
        try channel.send(line: line)
    }

    /// Feeds one line from the machine. Public so tests can drive the bridge
    /// without a channel.
    public func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            KanbanCodeLog.warn("boxd", "\(machineName): unreadable line from the agent: \(line.prefix(200))")
            return
        }
        switch type {
        case "hello":
            remoteHome = object["home"] as? String
            agentVersion = object["agentVersion"] as? String
            connected = true
            let waiters = helloWaiters
            helloWaiters = [:]
            for waiter in waiters.values { waiter.resume() }
            eventContinuation.yield(.hello(
                agentVersion: agentVersion ?? "",
                home: remoteHome ?? "",
                vm: object["vm"] as? String ?? machineName
            ))
        case "file":
            guard let path = object["path"] as? String,
                  let base64 = object["data"] as? String,
                  let bytes = Data(base64Encoded: base64) else { return }
            eventContinuation.yield(.file(
                path: path,
                cwd: object["cwd"] as? String,
                offset: (object["offset"] as? Int) ?? 0,
                data: bytes,
                eof: (object["eof"] as? Bool) ?? true
            ))
        case "removed":
            guard let path = object["path"] as? String else { return }
            eventContinuation.yield(.removed(path: path))
        case "proxy":
            guard let id = object["id"] as? String else { return }
            let images = ((object["images"] as? [[String: Any]]) ?? []).compactMap { image -> BridgeProxyRequest.Image? in
                guard let name = image["name"] as? String,
                      let base64 = image["base64"] as? String ?? image["data"] as? String,
                      let bytes = Data(base64Encoded: base64) else { return nil }
                return BridgeProxyRequest.Image(name: name, data: bytes)
            }
            eventContinuation.yield(.proxy(BridgeProxyRequest(
                id: id,
                argv: (object["argv"] as? [String]) ?? [],
                cwd: object["cwd"] as? String,
                stdin: object["stdin"] as? String,
                env: (object["env"] as? [String: String]) ?? [:],
                images: images
            )))
        case "exec-result":
            guard let id = object["id"] as? String, let continuation = pendingExecs.removeValue(forKey: id) else { return }
            continuation.resume(returning: ShellCommand.Result(
                exitCode: Int32((object["code"] as? Int) ?? 0),
                stdout: (object["stdout"] as? String) ?? "",
                stderr: (object["stderr"] as? String) ?? ""
            ))
        case "activity":
            eventContinuation.yield(.activity(kind: (object["kind"] as? String) ?? "transcript"))
        case "pong":
            let waiters = pendingPongs
            pendingPongs = [:]
            for waiter in waiters.values { waiter.resume() }
        default:
            KanbanCodeLog.debug("boxd", "\(machineName): unknown message type \(type)")
        }
    }

    private func finish(reason: String) {
        guard connected || !helloWaiters.isEmpty || !pendingExecs.isEmpty || readerTask != nil else { return }
        connected = false
        for continuation in pendingExecs.values { continuation.resume(throwing: BoxdBridgeError.disconnected) }
        pendingExecs = [:]
        for waiter in pendingPongs.values { waiter.resume(throwing: BoxdBridgeError.disconnected) }
        pendingPongs = [:]
        for waiter in helloWaiters.values { waiter.resume(throwing: BoxdBridgeError.disconnected) }
        helloWaiters = [:]
        eventContinuation.yield(.disconnected(reason: reason))
        eventContinuation.finish()
        KanbanCodeLog.info("boxd", "\(machineName): bridge closed (\(reason))")
    }
}
