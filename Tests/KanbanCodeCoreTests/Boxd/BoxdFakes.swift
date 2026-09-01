import Foundation
@testable import KanbanCodeCore

/// `NSLock` cannot be taken from an async function, so every fake below runs
/// its critical section through this synchronous helper.
private func withLock<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

// MARK: - Remote command runner

/// A `RemoteCommandRunner` that answers from a scripted table and records
/// everything it was asked to do.
final class FakeRemoteCommandRunner: RemoteCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _execCalls: [[String]] = []
    private var _files: [String: Data] = [:]
    private var _fileModes: [String: Int?] = [:]
    private var _removed: [String] = []
    private var _connected = true
    private var _table: [String: ShellCommand.Result] = [:]
    private var _fallback = ShellCommand.Result(exitCode: 0, stdout: "", stderr: "")

    init(connected: Bool = true) {
        self._connected = connected
    }

    var execCalls: [[String]] { withLock(lock) { _execCalls } }
    var files: [String: Data] { withLock(lock) { _files } }
    var removedPaths: [String] { withLock(lock) { _removed } }

    func mode(of path: String) -> Int? {
        withLock(lock) { _fileModes[path] ?? nil }
    }

    var connected: Bool {
        get { withLock(lock) { _connected } }
        set { withLock(lock) { _connected = newValue } }
    }

    /// Scripts the answer to one exact argv.
    func script(_ argv: [String], _ result: ShellCommand.Result) {
        withLock(lock) { _table[key(argv)] = result }
    }

    func setFallback(_ result: ShellCommand.Result) {
        withLock(lock) { _fallback = result }
    }

    func exec(_ argv: [String], stdin: String?, cwd: String?, timeout: TimeInterval) async throws -> ShellCommand.Result {
        withLock(lock) {
            _execCalls.append(argv)
            return _table[key(argv)] ?? _fallback
        }
    }

    func put(path: String, data: Data, mode: Int?) async throws {
        withLock(lock) {
            _files[path] = data
            _fileModes[path] = mode
        }
    }

    func remove(path: String) async throws {
        withLock(lock) {
            _files[path] = nil
            _removed.append(path)
        }
    }

    func isConnected() async -> Bool { connected }

    private func key(_ argv: [String]) -> String { argv.joined(separator: "\u{1}") }
}

// MARK: - Tmux transport

/// A `TmuxTransport` that records the tmux argv it was given.
final class FakeTmuxTransport: TmuxTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _tempFiles: [String: String] = [:]
    private var _table: [String: ShellCommand.Result] = [:]
    private var _fallback = ShellCommand.Result(exitCode: 0, stdout: "", stderr: "")
    private var _available = true
    let label: String

    init(label: String = "fake") {
        self.label = label
    }

    var calls: [[String]] { withLock(lock) { _calls } }
    var tempFiles: [String: String] { withLock(lock) { _tempFiles } }

    func script(_ argv: [String], _ result: ShellCommand.Result) {
        withLock(lock) { _table[key(argv)] = result }
    }

    func setAvailable(_ value: Bool) {
        withLock(lock) { _available = value }
    }

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellCommand.Result {
        withLock(lock) {
            _calls.append(arguments)
            return _table[key(arguments)] ?? _fallback
        }
    }

    func writeTempFile(name: String, contents: String) async throws -> String {
        withLock(lock) {
            let path = "/fake/\(label)/\(name)"
            _tempFiles[path] = contents
            return path
        }
    }

    func removeTempFile(_ path: String) async {
        withLock(lock) { _tempFiles[path] = nil }
    }

    func isAvailable() async -> Bool {
        withLock(lock) { _available }
    }

    private func key(_ argv: [String]) -> String { argv.joined(separator: "\u{1}") }
}

// MARK: - Bridge channel

/// A `BridgeChannel` over an `AsyncStream` the test feeds by hand.
final class FakeBridgeChannel: BridgeChannel, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _closed = false
    private var _reason = "exit 0"

    init() {
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        self.lines = stream
        self.continuation = continuation
    }

    var sent: [String] { withLock(lock) { _sent } }
    var isClosed: Bool { withLock(lock) { _closed } }

    /// Every sent line parsed as a JSON object.
    var sentObjects: [[String: Any]] {
        sent.compactMap {
            guard let data = $0.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    func lastSent(type: String) -> [String: Any]? {
        sentObjects.last { ($0["type"] as? String) == type }
    }

    func setTerminationReason(_ reason: String) {
        withLock(lock) { _reason = reason }
    }

    /// Pushes one line from the "machine" to the bridge.
    func feed(_ line: String) {
        continuation.yield(line)
    }

    func feed(json object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        continuation.yield(String(data: data, encoding: .utf8)!)
    }

    /// Ends the line stream, as a dead process would.
    func finish() {
        continuation.finish()
    }

    func send(line: String) throws {
        let closed = withLock(lock) { () -> Bool in
            if !_closed { _sent.append(line) }
            return _closed
        }
        if closed { throw BoxdBridgeError.disconnected }
    }

    func close() {
        withLock(lock) { _closed = true }
        continuation.finish()
    }

    func terminationReason() async -> String {
        withLock(lock) { _reason }
    }
}

// MARK: - Boxd port

/// A `BoxdPort` that records its calls and answers from scripted results.
final class FakeBoxdPort: BoxdPort, @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let argument: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _errors: [String: BoxdError] = [:]
    private var _machines: [String: BoxdMachine] = [:]

    var calls: [Call] { withLock(lock) { _calls } }

    func callNames(_ name: String) -> [String] {
        calls.filter { $0.name == name }.map(\.argument)
    }

    /// Makes every call of `name` throw.
    func fail(_ name: String, with error: BoxdError) {
        withLock(lock) { _errors[name] = error }
    }

    func setMachine(_ machine: BoxdMachine) {
        withLock(lock) { _machines[machine.name] = machine }
    }

    private func record(_ name: String, _ argument: String) throws {
        let error = withLock(lock) { () -> BoxdError? in
            _calls.append(Call(name: name, argument: argument))
            return _errors[name]
        }
        if let error { throw error }
    }

    func createMachine(name: String, snapshot: String?, autoSuspendSeconds: Int?) async throws -> BoxdMachine {
        try record("createMachine", name)
        return machine(named: name)
    }

    func getMachine(name: String) async throws -> BoxdMachine {
        try record("getMachine", name)
        return machine(named: name)
    }

    func listMachines() async throws -> [BoxdMachine] {
        try record("listMachines", "")
        return withLock(lock) { Array(_machines.values) }
    }

    func pause(name: String) async throws { try record("pause", name) }
    func resume(name: String) async throws { try record("resume", name) }
    func wake(name: String) async throws { try record("wake", name) }
    func start(name: String) async throws { try record("start", name) }
    func stop(name: String) async throws { try record("stop", name) }
    func remove(name: String) async throws { try record("remove", name) }
    func saveSnapshot(machine: String, name: String) async throws { try record("saveSnapshot", machine) }

    func listSnapshots() async throws -> [BoxdSnapshot] {
        try record("listSnapshots", "")
        return []
    }

    func exec(name: String, command: String, timeout: TimeInterval) async throws -> ShellCommand.Result {
        try record("exec", command)
        return ShellCommand.Result(exitCode: 0, stdout: "", stderr: "")
    }

    func upload(name: String, remotePath: String, data: Data) async throws {
        try record("upload", remotePath)
    }

    func isAvailable() async -> Bool { true }

    private func machine(named name: String) -> BoxdMachine {
        withLock(lock) { _machines[name] ?? BoxdMachine(name: name, id: name, status: .running) }
    }
}
