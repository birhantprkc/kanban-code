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
    func resume(name: String) async throws
    func wake(name: String) async throws
    func start(name: String) async throws
    func stop(name: String) async throws
    func remove(name: String) async throws
    func saveSnapshot(machine: String, name: String) async throws
    func listSnapshots() async throws -> [BoxdSnapshot]
    func exec(name: String, command: String, timeout: TimeInterval) async throws -> ShellCommand.Result
    /// Uploads bytes to a path on the machine, reporting what happens on the
    /// way so a launch can show it.
    func upload(name: String, remotePath: String, data: Data, onEvent: @escaping @Sendable (BoxdUploadEvent) -> Void) async throws
    func isAvailable() async -> Bool
}

/// What an upload reports while it runs.
public enum BoxdUploadEvent: Sendable, Equatable {
    /// Bytes that have landed on the machine so far.
    case progress(sent: Int, total: Int)
    /// A part failed and is being sent again.
    case retry(attempt: Int, of: Int, reason: String)
}

extension BoxdPort {
    public func exec(name: String, command: String) async throws -> ShellCommand.Result {
        try await exec(name: name, command: command, timeout: 120)
    }

    public func upload(name: String, remotePath: String, data: Data) async throws {
        try await upload(name: name, remotePath: remotePath, data: data, onEvent: { _ in })
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

    /// Size of one part of an upload. The transfer behind `machine cp` is
    /// cut after about a minute whatever is left to send, so one big file
    /// never gets through a slow uplink; a part this size takes a second or
    /// two on the uplink boxd offers, and each part costs a process start
    /// and a TLS handshake, so smaller parts only add overhead.
    static let uploadPartBytes = 4 * 1024 * 1024
    /// How often one part is sent before the upload fails.
    static let uploadPartTries = 3

    /// Uploads bytes to a path on the machine, in parts.
    ///
    /// Each part goes through a temporary file rather than the stdin form of
    /// `machine cp -`: `ShellCommand.run` writes its stdin before the child
    /// starts, which blocks forever once the payload passes the pipe buffer.
    /// `boxd machine cp` stages an upload in `<target>.boxd-upload.tmp` on
    /// the machine, so two uploads to the same target destroy each other at
    /// the rename: the parts land on their own names and one command on the
    /// machine folds them into the target.
    ///
    /// The bytes travel gzipped: a transcript shrinks about three times, and
    /// the uplink is the slow part. Progress is reported in the bytes of the
    /// payload, so the caller's total stays the size it knows.
    public func upload(name: String, remotePath: String, data: Data, onEvent: @escaping @Sendable (BoxdUploadEvent) -> Void) async throws {
        let incoming = "\(remotePath).incoming-\(UUID().uuidString.prefix(8))"
        let compressed = Self.gzip(data)
        let payload = compressed ?? data
        let parts = Self.parts(of: payload, size: Self.uploadPartBytes)
        let partPaths = parts.indices.map { "\(incoming).part-\($0)" }
        KanbanCodeLog.info(Self.subsystem, "Uploading \(data.count) bytes (\(payload.count) on the wire) to \(name):\(remotePath) in \(parts.count) part(s)")
        do {
            var sent = 0
            for (part, path) in zip(parts, partPaths) {
                try await uploadPart(part, to: path, machine: name, onEvent: onEvent)
                sent += part.count
                onEvent(.progress(sent: Self.scaled(sent, of: payload.count, to: data.count), total: data.count))
            }
            let list = partPaths.map(Self.quote).joined(separator: " ")
            let unpack = compressed == nil ? "cat \(list)" : "cat \(list) | gunzip -c"
            let assemble = "\(unpack) > \(Self.quote(incoming)) && rm -f \(list) && mv -f \(Self.quote(incoming)) \(Self.quote(remotePath))"
            _ = try await run(["machine", "exec", name, "--", "sh", "-c", assemble], timeout: 120)
        } catch {
            let list = ([incoming] + partPaths).map(Self.quote).joined(separator: " ")
            _ = try? await run(["machine", "exec", name, "--", "sh", "-c", "rm -f \(list)"], timeout: 30)
            throw error
        }
    }

    private func uploadPart(_ part: Data, to remotePath: String, machine: String, onEvent: @escaping @Sendable (BoxdUploadEvent) -> Void) async throws {
        let temporaryPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("kanban-boxd-upload-\(UUID().uuidString)")
        try part.write(to: URL(fileURLWithPath: temporaryPath))
        defer { try? FileManager.default.removeItem(atPath: temporaryPath) }
        var attempt = 1
        while true {
            do {
                _ = try await run(["machine", "cp", temporaryPath, "\(machine):\(remotePath)"], timeout: 180)
                return
            } catch {
                guard attempt < Self.uploadPartTries else { throw error }
                let reason = Self.shortMessage(of: error)
                KanbanCodeLog.warn(Self.subsystem, "upload of \(remotePath) failed on try \(attempt) (\(reason)), retrying")
                attempt += 1
                onEvent(.retry(attempt: attempt, of: Self.uploadPartTries, reason: reason))
                try? await Task.sleep(for: .seconds(2 * attempt))
            }
        }
    }

    /// `data` in gzip form, through the system `gzip` at its fastest level;
    /// nil when that is not possible, in which case the bytes go as they are.
    static func gzip(_ data: Data) -> Data? {
        let temporaryPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("kanban-boxd-gzip-\(UUID().uuidString)")
        let compressedPath = temporaryPath + ".gz"
        defer {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            try? FileManager.default.removeItem(atPath: compressedPath)
        }
        do {
            try data.write(to: URL(fileURLWithPath: temporaryPath))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-1", "-n", temporaryPath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try Data(contentsOf: URL(fileURLWithPath: compressedPath))
        } catch {
            KanbanCodeLog.warn(Self.subsystem, "gzip of an upload failed (\(error.localizedDescription)), sending it as it is")
            return nil
        }
    }

    /// `sent` bytes of a payload of `wire` bytes, as bytes of the `total`
    /// they stand for.
    static func scaled(_ sent: Int, of wire: Int, to total: Int) -> Int {
        guard wire > 0 else { return total }
        if sent >= wire { return total }
        return Int(Double(sent) / Double(wire) * Double(total))
    }

    /// The upload split into parts of `size` bytes; empty data is one empty
    /// part, so the target file still gets created.
    static func parts(of data: Data, size: Int) -> [Data] {
        guard !data.isEmpty else { return [Data()] }
        return stride(from: 0, to: data.count, by: size).map { start in
            data.subdata(in: start..<min(start + size, data.count))
        }
    }

    /// The reason of a failed command without the command itself.
    public static func shortMessage(of error: Error) -> String {
        if case .commandFailed(_, _, let message) = error as? BoxdError {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("error: ") ? String(trimmed.dropFirst(7)) : trimmed
        }
        return error.localizedDescription
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
