import Foundation

/// Where a `TmuxAdapter` runs its tmux commands and writes its helper files.
///
/// The local transport runs the tmux binary of this Mac. The bridge transport
/// runs tmux on a boxd machine and writes the helper files there, so the
/// same adapter logic drives a remote tmux server.
public protocol TmuxTransport: Sendable {
    /// Runs `tmux <arguments>` and returns the result.
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellCommand.Result

    /// Writes a helper file (a prompt buffer or a launch script) and returns
    /// the path tmux can read it from.
    func writeTempFile(name: String, contents: String) async throws -> String

    /// Removes a helper file written by `writeTempFile`.
    func removeTempFile(_ path: String) async

    /// True when tmux can be reached through this transport.
    func isAvailable() async -> Bool
}

/// Runs tmux on this Mac.
public struct LocalTmuxTransport: TmuxTransport {
    public let tmuxPath: String

    public init(tmuxPath: String? = nil) {
        self.tmuxPath = tmuxPath ?? ShellCommand.findExecutable("tmux") ?? "tmux"
    }

    public func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellCommand.Result {
        try await ShellCommand.run(tmuxPath, arguments: arguments, timeout: timeout)
    }

    public func writeTempFile(name: String, contents: String) async throws -> String {
        let path = "/tmp/kanban-code-\(name)"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    public func removeTempFile(_ path: String) async {
        try? FileManager.default.removeItem(atPath: path)
    }

    public func isAvailable() async -> Bool {
        ShellCommand.findExecutable("tmux") != nil
    }
}

/// Runs commands and writes files on a remote machine.
///
/// `BoxdBridge` implements this over its long-lived exec; tests use a fake.
public protocol RemoteCommandRunner: Sendable {
    /// Runs `argv` on the machine. `argv[0]` is the program.
    func exec(_ argv: [String], stdin: String?, cwd: String?, timeout: TimeInterval) async throws -> ShellCommand.Result

    /// Writes `data` to `path` on the machine, creating parent directories.
    func put(path: String, data: Data, mode: Int?) async throws

    /// Removes a file on the machine.
    func remove(path: String) async throws

    /// True while the machine can take commands.
    func isConnected() async -> Bool
}

extension RemoteCommandRunner {
    public func exec(_ argv: [String]) async throws -> ShellCommand.Result {
        try await exec(argv, stdin: nil, cwd: nil, timeout: 20)
    }
}

/// Runs tmux on a remote machine through a `RemoteCommandRunner`.
public struct BridgeTmuxTransport: TmuxTransport {
    public let runner: any RemoteCommandRunner
    /// Home directory on the machine, used for the helper files.
    public let remoteHome: String

    public init(runner: any RemoteCommandRunner, remoteHome: String) {
        self.runner = runner
        self.remoteHome = remoteHome
    }

    public var tempDirectory: String { "\(remoteHome)/.kanban-code/tmp" }

    public func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellCommand.Result {
        try await runner.exec(["tmux"] + arguments, stdin: nil, cwd: nil, timeout: timeout)
    }

    public func writeTempFile(name: String, contents: String) async throws -> String {
        let path = "\(tempDirectory)/kanban-code-\(name)"
        try await runner.put(path: path, data: Data(contents.utf8), mode: nil)
        return path
    }

    public func removeTempFile(_ path: String) async {
        try? await runner.remove(path: path)
    }

    public func isAvailable() async -> Bool {
        await runner.isConnected()
    }
}
