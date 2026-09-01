import Foundation

/// State of a boxd machine.
///
/// `machine list --json` and `machine get --json` report a suspended machine as
/// `standby`. Values this app does not know decode as `.unknown` instead of
/// failing the whole response.
public enum BoxdMachineStatus: String, Codable, Sendable {
    case running
    case booting
    case stopping
    case standby
    case hibernated
    case stopped
    case destroyed
    case unknown

    /// True when the machine keeps its memory, so a tmux session survives.
    public var keepsMemory: Bool {
        switch self {
        case .running, .booting, .standby: true
        case .stopping, .hibernated, .stopped, .destroyed, .unknown: false
        }
    }

    public init(rawStatus: String) {
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "suspended", "paused": self = .standby
        case "hibernating": self = .hibernated
        case let value: self = BoxdMachineStatus(rawValue: value) ?? .unknown
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawStatus: try container.decode(String.self))
    }
}

/// A boxd machine as the CLI reports it.
///
/// `machine list --json` carries no `id` and `machine new --json` carries no
/// `status`, so both are optional and every other field is tolerated missing.
public struct BoxdMachine: Codable, Sendable, Equatable {
    public let name: String
    public let id: String?
    public let status: BoxdMachineStatus
    public let url: String?
    public let source: String?

    public init(name: String, id: String? = nil, status: BoxdMachineStatus = .unknown, url: String? = nil, source: String? = nil) {
        self.name = name
        self.id = id
        self.status = status
        self.url = url
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        status = (try? c.decodeIfPresent(BoxdMachineStatus.self, forKey: .status)) ?? .unknown
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
    }

    private enum CodingKeys: String, CodingKey {
        case name, id, status, url, source
    }
}

/// A snapshot as `boxd snapshots list --json` reports it.
public struct BoxdSnapshot: Codable, Sendable, Equatable {
    public let name: String
    public let version: String?
    public let status: String?
    public let size: String?

    public init(name: String, version: String? = nil, status: String? = nil, size: String? = nil) {
        self.name = name
        self.version = version
        self.status = status
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        size = try? c.decodeIfPresent(String.self, forKey: .size)
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, status, size
    }
}

/// Everything Kanban Code asks the boxd CLI to do.
public protocol BoxdPort: Sendable {
    func createMachine(name: String, snapshot: String?, autoSuspendSeconds: Int?) async throws -> BoxdMachine
    func getMachine(name: String) async throws -> BoxdMachine
    func listMachines() async throws -> [BoxdMachine]
    func pause(name: String) async throws
    func resume(name: String) async throws
    func wake(name: String) async throws
    func start(name: String) async throws
    func stop(name: String) async throws
    func remove(name: String) async throws
    func saveSnapshot(machine: String, name: String) async throws
    func listSnapshots() async throws -> [BoxdSnapshot]
    func exec(name: String, command: String, timeout: TimeInterval) async throws -> ShellCommand.Result
    func upload(name: String, remotePath: String, data: Data) async throws
    func isAvailable() async -> Bool
}

extension BoxdPort {
    public func exec(name: String, command: String) async throws -> ShellCommand.Result {
        try await exec(name: name, command: command, timeout: 120)
    }
}

/// `BoxdPort` over the `boxd` CLI.
public final class BoxdCliAdapter: BoxdPort, @unchecked Sendable {
    private static let subsystem = "boxd"

    private let boxdPath: String
    /// Grace added to the boxd `--timeout` before the local process is killed.
    private static let execGraceSeconds: TimeInterval = 15

    public init(boxdPath: String? = nil) {
        self.boxdPath = boxdPath ?? ShellCommand.findExecutable("boxd") ?? "boxd"
    }

    // MARK: - Machines

    public func createMachine(name: String, snapshot: String?, autoSuspendSeconds: Int?) async throws -> BoxdMachine {
        var arguments = ["machine", "new", name]
        if let snapshot, !snapshot.isEmpty {
            arguments += ["--from-snapshot", snapshot]
        }
        if let autoSuspendSeconds {
            arguments += ["--auto-suspend-timeout=\(autoSuspendSeconds)"]
        }
        arguments.append("--json")
        let output = try await runJSON(arguments, timeout: 300)
        return try Self.decodeMachine(output)
    }

    public func getMachine(name: String) async throws -> BoxdMachine {
        let output = try await runJSON(["machine", "get", name, "--json"], timeout: 60)
        return try Self.decodeMachine(output)
    }

    public func listMachines() async throws -> [BoxdMachine] {
        let output = try await runJSON(["machine", "list", "--json"], timeout: 60)
        return try Self.decodeMachines(output)
    }

    public func pause(name: String) async throws {
        _ = try await runJSON(["machine", "pause", name, "--json"], timeout: 120)
    }

    public func resume(name: String) async throws {
        _ = try await runJSON(["machine", "resume", name, "--json"], timeout: 120)
    }

    public func wake(name: String) async throws {
        _ = try await runJSON(["machine", "wake", name, "--json"], timeout: 180)
    }

    public func start(name: String) async throws {
        _ = try await runJSON(["machine", "start", name, "--json"], timeout: 180)
    }

    public func stop(name: String) async throws {
        _ = try await runJSON(["machine", "stop", name, "--json"], timeout: 180)
    }

    public func remove(name: String) async throws {
        _ = try await runJSON(["machine", "remove", name, "--confirm", "--json"], timeout: 180)
    }

    // MARK: - Snapshots

    public func saveSnapshot(machine: String, name: String) async throws {
        _ = try await run(["snapshots", "save", machine, name], timeout: 900)
    }

    public func listSnapshots() async throws -> [BoxdSnapshot] {
        let output = try await runJSON(["snapshots", "list", "--json"], timeout: 60)
        return try Self.decodeSnapshots(output)
    }

    // MARK: - Commands and files

    public func exec(name: String, command: String, timeout: TimeInterval) async throws -> ShellCommand.Result {
        let seconds = max(1, Int(timeout.rounded()))
        return try await run(
            ["machine", "exec", name, "--timeout", String(seconds), "--", command],
            timeout: timeout + Self.execGraceSeconds
        )
    }

    /// Uploads bytes to a path on the machine.
    ///
    /// The bytes go through a temporary file rather than the stdin form of
    /// `machine cp -`: `ShellCommand.run` writes its stdin before the child
    /// starts, which blocks forever once the payload passes the pipe buffer.
    public func upload(name: String, remotePath: String, data: Data) async throws {
        let temporaryPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("kanban-boxd-upload-\(UUID().uuidString)")
        try data.write(to: URL(fileURLWithPath: temporaryPath))
        defer { try? FileManager.default.removeItem(atPath: temporaryPath) }
        _ = try await run(["machine", "cp", temporaryPath, "\(name):\(remotePath)"], timeout: 300)
    }

    public func isAvailable() async -> Bool {
        ShellCommand.findExecutable("boxd") != nil || FileManager.default.isExecutableFile(atPath: boxdPath)
    }

    // MARK: - Private

    @discardableResult
    private func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellCommand.Result {
        let result = try await ShellCommand.run(boxdPath, arguments: arguments, timeout: timeout)
        if !result.succeeded {
            let command = (["boxd"] + arguments).joined(separator: " ")
            KanbanCodeLog.warn(Self.subsystem, "\(command) exited \(result.exitCode): \(result.stderr)")
            throw BoxdError.commandFailed(
                command: command,
                exitCode: result.exitCode,
                message: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result
    }

    private func runJSON(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        let result = try await run(arguments, timeout: timeout)
        KanbanCodeLog.debug(Self.subsystem, "\((["boxd"] + arguments).joined(separator: " ")) → \(result.stdout.prefix(400))")
        return result.stdout
    }

    // MARK: - Decoding

    static func decodeMachine(_ json: String) throws -> BoxdMachine {
        try decode(BoxdMachine.self, from: json)
    }

    static func decodeMachines(_ json: String) throws -> [BoxdMachine] {
        try decode([BoxdMachine].self, from: json)
    }

    static func decodeSnapshots(_ json: String) throws -> [BoxdSnapshot] {
        try decode([BoxdSnapshot].self, from: json)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8), !data.isEmpty else {
            throw BoxdError.unreadableOutput(json)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            KanbanCodeLog.warn(subsystem, "cannot read the boxd output: \(error)")
            throw BoxdError.unreadableOutput(json)
        }
    }
}

public enum BoxdError: Error, LocalizedError, Equatable {
    case notInstalled
    case commandFailed(command: String, exitCode: Int32, message: String)
    case unreadableOutput(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The boxd CLI is not installed"
        case .commandFailed(let command, let exitCode, let message):
            "`\(command)` failed with code \(exitCode): \(message)"
        case .unreadableOutput:
            "The boxd CLI returned output this version cannot read"
        }
    }
}
