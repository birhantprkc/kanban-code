import Foundation

/// Keeps one git clone in step with its origin: clones it where missing,
/// fetches, fast-forwards, and pushes local commits. Never forces: a clone
/// that diverged from its upstream, or whose local changes block a
/// fast-forward, is reported and left alone.
public struct GitRepoSync: Sendable {
    public struct Outcome: Sendable, Equatable {
        public var level: SyncEntryStatus.Level
        public var message: String
        public var info: SyncGitInfo
        /// Local commits went to the origin: peers should fetch.
        public var pushed: Bool

        public init(level: SyncEntryStatus.Level, message: String, info: SyncGitInfo = SyncGitInfo(), pushed: Bool = false) {
            self.level = level
            self.message = message
            self.info = info
            self.pushed = pushed
        }
    }

    public typealias Runner = @Sendable (_ args: [String], _ cwd: String?) async -> ShellCommand.Result

    let run: Runner

    public init(run: @escaping Runner = GitRepoSync.shell) {
        self.run = run
    }

    public static let shell: Runner = { args, cwd in
        let git = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
        var env = ShellCommand.loginEnvironment
        env["GIT_TERMINAL_PROMPT"] = "0"
        do {
            return try await ShellCommand.run(git, arguments: args, currentDirectory: cwd, environment: env, timeout: 120)
        } catch {
            return ShellCommand.Result(exitCode: -1, stdout: "", stderr: "\(error)")
        }
    }

    /// The origin URL, branch and head of the clone at `path`, if any.
    public func info(path: String) async -> SyncGitInfo? {
        guard FileManager.default.fileExists(atPath: path + "/.git") else { return nil }
        let url = await run(["remote", "get-url", "origin"], path)
        let branch = await run(["rev-parse", "--abbrev-ref", "HEAD"], path)
        let head = await run(["rev-parse", "HEAD"], path)
        return SyncGitInfo(
            url: url.succeeded ? url.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            head: head.succeeded ? head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            branch: branch.succeeded ? branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
    }

    /// One round: clone (from `url`) when missing, fetch, fast-forward, push.
    public func sync(path: String, url: String?) async -> Outcome {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path + "/.git") {
            if fm.fileExists(atPath: path),
               let items = try? fm.contentsOfDirectory(atPath: path), !items.isEmpty {
                return Outcome(level: .warning, message: "\(path) exists and is not a git clone")
            }
            guard let url, !url.isEmpty else {
                return Outcome(level: .info, message: "not cloned here; waiting for a peer to tell the origin URL")
            }
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let clone = await run(["clone", "--quiet", url, path], nil)
            guard clone.succeeded else {
                return Outcome(level: .error, message: "clone failed: \(Self.firstLine(clone))")
            }
            return Outcome(level: .ok, message: "cloned from \(url)", info: await info(path: path) ?? SyncGitInfo(url: url))
        }

        let fetch = await run(["fetch", "--quiet", "origin"], path)
        var current = await info(path: path) ?? SyncGitInfo()
        guard fetch.succeeded else {
            return Outcome(level: .error, message: "fetch failed: \(Self.firstLine(fetch))", info: current)
        }
        let upstream = await run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], path)
        guard upstream.succeeded else {
            return Outcome(level: .warning, message: "branch \(current.branch ?? "?") has no upstream", info: current)
        }
        let counts = await run(["rev-list", "--left-right", "--count", "HEAD...@{u}"], path)
        let numbers = counts.stdout.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).compactMap { Int($0) }
        guard counts.succeeded, numbers.count == 2 else {
            return Outcome(level: .error, message: "cannot compare with upstream: \(Self.firstLine(counts))", info: current)
        }
        let (ahead, behind) = (numbers[0], numbers[1])
        let dirty = await run(["status", "--porcelain"], path)
        let dirtyNote = dirty.succeeded && !dirty.stdout.isEmpty ? " (uncommitted changes stay local)" : ""

        if ahead > 0 && behind > 0 {
            return Outcome(
                level: .warning,
                message: "diverged: \(ahead) local and \(behind) upstream commits; merge or rebase by hand",
                info: current
            )
        }
        if behind > 0 {
            let merge = await run(["merge", "--ff-only", "--quiet", "@{u}"], path)
            current = await info(path: path) ?? current
            guard merge.succeeded else {
                return Outcome(level: .warning, message: "cannot fast-forward \(behind) commits: \(Self.firstLine(merge))", info: current)
            }
            return Outcome(level: .ok, message: "pulled \(behind) commit\(behind == 1 ? "" : "s")\(dirtyNote)", info: current)
        }
        if ahead > 0 {
            let push = await run(["push", "--quiet"], path)
            guard push.succeeded else {
                return Outcome(level: .warning, message: "push of \(ahead) commits failed: \(Self.firstLine(push))", info: current)
            }
            return Outcome(level: .ok, message: "pushed \(ahead) commit\(ahead == 1 ? "" : "s")\(dirtyNote)", info: current, pushed: true)
        }
        return Outcome(level: .ok, message: "up to date\(dirtyNote)", info: current)
    }

    static func firstLine(_ result: ShellCommand.Result) -> String {
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        return text.split(separator: "\n").first.map(String.init) ?? "exit \(result.exitCode)"
    }
}
