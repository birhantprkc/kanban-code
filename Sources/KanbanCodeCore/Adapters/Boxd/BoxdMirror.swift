import Foundation

/// What the mirror did with a bridge file event.
public enum MirrorOutcome: Sendable, Equatable {
    /// Lines were appended to a local transcript mirror.
    case transcript(sessionId: String, localPath: String)
    /// A sidecar file (tool result, subagent transcript) was written.
    case sidecar(localPath: String)
    /// Hook events were relayed into the local `hook-events.jsonl`.
    case hookEvents(count: Int)
    /// A statusline context file was written.
    case context(localPath: String)
    /// The bytes wait until the transcript's working directory is known.
    case buffered(path: String)
    /// The path is not one the mirror handles.
    case ignored(path: String)
    /// A file the mirror had was removed on the machine.
    case removed(localPath: String)
}

/// Keeps a local copy of what a machine writes: transcripts under
/// `~/.claude/projects` and `~/.codex/sessions`, their sidecar files, the
/// hook events and the statusline context files.
///
/// Every `.jsonl` line is rewritten to local paths on the way in, so the
/// local copy resumes with a plain `claude --resume` at any time. Byte
/// offsets per remote path are kept on disk, so a reconnect only asks the
/// machine for what the Mac does not have yet.
public actor BoxdMirror {
    public let machineName: String
    public let remoteHome: String
    public let localHome: String
    public let localKanbanHome: String
    public private(set) var rewriter: TranscriptPathRewriter

    /// Remote path → bytes the Mac already holds.
    public private(set) var offsets: [String: Int]
    /// Remote project directory (the encoded one) → local project directory.
    private var projectDirectories: [String: String]
    /// Events held back until their transcript's working directory is known.
    private var pending: [String: [BridgeEvent]] = [:]
    /// Remote paths whose events are held while the Mac rewrites the local file.
    private var suspended: Set<String> = []
    private let stateDirectory: String
    private let now: @Sendable () -> Date

    public init(
        machineName: String,
        rewriter: TranscriptPathRewriter,
        remoteHome: String,
        localHome: String = NSHomeDirectory(),
        localKanbanHome: String? = nil,
        stateDirectory: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let home = PathMapping(from: localHome, to: "").from
        let kanbanHome = localKanbanHome ?? "\(home)/.kanban-code"
        let stateDir = stateDirectory ?? "\(kanbanHome)/boxd/\(machineName)"
        let saved = FileManager.default.contents(atPath: "\(stateDir)/mirror.json")
            .flatMap { try? JSONDecoder().decode(PersistedState.self, from: $0) }
        self.machineName = machineName
        self.rewriter = rewriter
        self.remoteHome = PathMapping(from: remoteHome, to: "").from
        self.localHome = home
        self.localKanbanHome = kanbanHome
        self.stateDirectory = stateDir
        self.now = now
        self.offsets = saved?.offsets ?? [:]
        self.projectDirectories = saved?.projectDirectories ?? [:]
    }

    // MARK: - Remote layout

    public var remoteKanbanHome: String { "\(remoteHome)/.kanban-code" }
    public var remoteClaudeProjects: String { "\(remoteHome)/.claude/projects" }
    public var remoteCodexSessions: String { "\(remoteHome)/.codex/sessions" }
    public var remoteHookEvents: String { "\(remoteKanbanHome)/hook-events.jsonl" }
    public var remoteContextDirectory: String { "\(remoteKanbanHome)/context" }

    public var localClaudeProjects: String { "\(localHome)/.claude/projects" }
    public var localCodexSessions: String { "\(localHome)/.codex/sessions" }
    public var localHookEvents: String { "\(localKanbanHome)/hook-events.jsonl" }
    public var localContextDirectory: String { "\(localKanbanHome)/context" }

    /// The roots the machine has to watch for this mirror.
    public var watchRoots: [BridgeWatchRoot] {
        [
            BridgeWatchRoot(path: remoteClaudeProjects, globs: ["**/*.jsonl", "**/tool-results/*", "**/subagents/*"]),
            BridgeWatchRoot(path: remoteCodexSessions, globs: ["**/*.jsonl"]),
            BridgeWatchRoot(path: remoteHookEvents),
            BridgeWatchRoot(path: remoteContextDirectory, globs: ["*.json"]),
        ]
    }

    /// Replaces the path mappings, for example when a card's project changes.
    public func setRewriter(_ rewriter: TranscriptPathRewriter) {
        self.rewriter = rewriter
    }

    /// Seeds offsets for files the Mac does not want: everything that was on
    /// the machine before the first connection (a snapshot carries the
    /// sessions of the machine it was saved from).
    public func seedOffsets(_ sizes: [String: Int]) {
        for (path, size) in sizes where offsets[path] == nil {
            offsets[path] = size
        }
        saveState()
    }

    /// Records that the Mac wrote `bytes` bytes to `remotePath` itself (a
    /// pushed transcript), so the machine does not send them back.
    public func recordPushed(remotePath: String, bytes: Int, localProjectDirectory: String? = nil) {
        offsets[remotePath] = bytes
        if let localProjectDirectory, let remoteDirectory = remoteProjectDirectory(of: remotePath) {
            projectDirectories[remoteDirectory] = localProjectDirectory
        }
        saveState()
    }

    /// Holds events for `remotePath` while the Mac edits the local file.
    public func suspend(remotePath: String) {
        suspended.insert(remotePath)
    }

    public func resume(remotePath: String) {
        suspended.remove(remotePath)
        if let held = pending.removeValue(forKey: remotePath) {
            for event in held { _ = apply(event) }
        }
    }

    // MARK: - Path mapping

    /// Local mirror path of a remote transcript, once its working directory
    /// is known. `cwd` is the working directory on the machine.
    public func localPath(forRemote remotePath: String, cwd: String?) -> String? {
        if remotePath.hasPrefix(remoteCodexSessions + "/") {
            return localCodexSessions + remotePath.dropFirst(remoteCodexSessions.count)
        }
        guard remotePath.hasPrefix(remoteClaudeProjects + "/") else { return nil }
        let relative = String(remotePath.dropFirst(remoteClaudeProjects.count + 1))
        guard let slash = relative.firstIndex(of: "/") else { return nil }
        let remoteDirectory = String(relative[..<slash])
        let rest = String(relative[relative.index(after: slash)...])
        if let known = projectDirectories[remoteDirectory] {
            return "\(known)/\(rest)"
        }
        let localDirectory: String
        if let cwd {
            localDirectory = "\(localClaudeProjects)/\(TranscriptPathRewriter.encodeProjectPath(rewriter.mapPath(cwd)))"
        } else if let derived = localProjectDirectory(forRemoteDirectory: remoteDirectory) {
            localDirectory = derived
        } else {
            return nil
        }
        projectDirectories[remoteDirectory] = localDirectory
        saveState()
        return "\(localDirectory)/\(rest)"
    }

    /// Local project directory for an encoded remote one, from the path
    /// mappings. Both sides encode a path the same way, so when the remote
    /// name starts with the encoded `from` of a mapping, the rest of the name
    /// is the same on the Mac after the encoded `to`.
    private func localProjectDirectory(forRemoteDirectory remoteDirectory: String) -> String? {
        for mapping in rewriter.pathMappings {
            let encodedFrom = Self.encodeRemoteProjectPath(mapping.from)
            guard remoteDirectory == encodedFrom || remoteDirectory.hasPrefix(encodedFrom + "-") else { continue }
            let tail = remoteDirectory.dropFirst(encodedFrom.count)
            return "\(localClaudeProjects)/\(TranscriptPathRewriter.encodeProjectPath(mapping.to))\(tail)"
        }
        return nil
    }

    /// Where a local transcript goes on the machine. `remoteCwd` is the
    /// working directory the session has there.
    public func remotePath(forLocal localPath: String, remoteCwd: String) -> String? {
        if localPath.hasPrefix(localCodexSessions + "/") {
            return remoteCodexSessions + localPath.dropFirst(localCodexSessions.count)
        }
        guard localPath.hasPrefix(localClaudeProjects + "/") else { return nil }
        let relative = String(localPath.dropFirst(localClaudeProjects.count + 1))
        guard let slash = relative.firstIndex(of: "/") else { return nil }
        let rest = String(relative[relative.index(after: slash)...])
        let remoteDirectory = Self.encodeRemoteProjectPath(remoteCwd)
        projectDirectories[remoteDirectory] = "\(localClaudeProjects)/\(relative[..<slash])"
        saveState()
        return "\(remoteClaudeProjects)/\(remoteDirectory)/\(rest)"
    }

    /// Directory name Claude Code uses on the machine for `remoteCwd`. No
    /// symlink resolution: the path is not on this Mac.
    public static func encodeRemoteProjectPath(_ remoteCwd: String) -> String {
        remoteCwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    // MARK: - Events

    /// Applies one bridge event to the local file system.
    @discardableResult
    public func apply(_ event: BridgeEvent) -> MirrorOutcome? {
        switch event {
        case .file(let path, let cwd, let offset, let data, _):
            if suspended.contains(path) {
                pending[path, default: []].append(event)
                return .buffered(path: path)
            }
            return applyFile(path: path, cwd: cwd, offset: offset, data: data)
        case .removed(let path):
            offsets[path] = nil
            pending[path] = nil
            saveState()
            if let local = localPath(forRemote: path, cwd: nil), path.hasSuffix(".jsonl") || isSidecar(path) {
                // Transcripts are never deleted on the Mac because a machine
                // dropped them: the local copy is the one that survives.
                return .removed(localPath: local)
            }
            return .ignored(path: path)
        case .hello, .proxy, .activity, .disconnected:
            return nil
        }
    }

    private func applyFile(path: String, cwd: String?, offset: Int, data: Data) -> MirrorOutcome {
        if path == remoteHookEvents {
            return relayHookEvents(data: data, offset: offset, path: path)
        }
        if path.hasPrefix(remoteContextDirectory + "/") {
            let local = "\(localContextDirectory)/\((path as NSString).lastPathComponent)"
            write(data: rewriteAll(data), to: local, offset: offset, remoteBytes: data.count, remotePath: path)
            return .context(localPath: local)
        }
        let isTranscript = path.hasSuffix(".jsonl")
        guard isTranscript || isSidecar(path) else { return .ignored(path: path) }
        guard let local = localPath(forRemote: path, cwd: cwd) ?? localPathFromParent(path) else {
            pending[path, default: []].append(.file(path: path, cwd: cwd, offset: offset, data: data, eof: true))
            return .buffered(path: path)
        }
        // Chunks that arrived before the working directory was known come
        // first: they hold the opening lines of the transcript.
        if let held = pending.removeValue(forKey: path) {
            for case .file(_, _, let heldOffset, let heldData, _) in held {
                write(data: isTranscript ? rewriteAll(heldData) : heldData, to: local, offset: heldOffset, remoteBytes: heldData.count, remotePath: path)
            }
        }
        let bytes = isTranscript ? rewriteAll(data) : data
        write(data: bytes, to: local, offset: offset, remoteBytes: data.count, remotePath: path)
        if isSidecar(path) {
            return .sidecar(localPath: local)
        }
        let sessionId = ((local as NSString).lastPathComponent as NSString).deletingPathExtension
        return .transcript(sessionId: sessionId, localPath: local)
    }

    /// A sidecar file lives in `<projectDir>/<sessionId>/{tool-results,subagents}/`.
    private func isSidecar(_ path: String) -> Bool {
        guard path.hasPrefix(remoteClaudeProjects + "/") else { return false }
        let directory = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return directory == "tool-results" || directory == "subagents"
    }

    /// A sidecar file whose project directory was learned from its transcript.
    private func localPathFromParent(_ path: String) -> String? {
        guard isSidecar(path), let remoteDirectory = remoteProjectDirectory(of: path),
              let local = projectDirectories[remoteDirectory] else { return nil }
        let prefix = "\(remoteClaudeProjects)/\(remoteDirectory)/"
        return local + "/" + path.dropFirst(prefix.count)
    }

    private func remoteProjectDirectory(of path: String) -> String? {
        guard path.hasPrefix(remoteClaudeProjects + "/") else { return nil }
        let relative = path.dropFirst(remoteClaudeProjects.count + 1)
        guard let slash = relative.firstIndex(of: "/") else { return nil }
        return String(relative[..<slash])
    }

    private func rewriteAll(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }
        let rewritten = lines.map { rewriter.rewriteLine($0) }.joined(separator: "\n")
        return Data((rewritten + (endsWithNewline ? "\n" : "")).utf8)
    }

    /// Appends `data` to the local file, or replaces it when the machine
    /// sends it whole. An offset of zero always means the first byte of the
    /// remote file, so the local copy starts over: a rewritten file, such as
    /// the statusline context, would otherwise get its new content glued
    /// after the old one. Offsets are tracked in remote bytes, so a chunk
    /// that grows or shrinks does not shift them.
    private func write(data: Data, to localPath: String, offset: Int, remoteBytes: Int, remotePath: String) {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: (localPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let known = offsets[remotePath] ?? 0
        if offset == 0 || !manager.fileExists(atPath: localPath) {
            manager.createFile(atPath: localPath, contents: data)
        } else if let handle = FileHandle(forWritingAtPath: localPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
        if offset != known {
            KanbanCodeLog.debug("boxd", "\(machineName): \(remotePath) came at offset \(offset), expected \(known)")
        }
        offsets[remotePath] = offset + remoteBytes
        saveState()
    }

    // MARK: - Hook events

    /// Appends the machine's hook events to the local `hook-events.jsonl`,
    /// with `transcriptPath` pointing at the local mirror and `timestamp`
    /// set to now. The machine clock freezes while it is paused, so its
    /// timestamps say nothing about when the event reached the Mac.
    private func relayHookEvents(data: Data, offset: Int, path: String) -> MirrorOutcome {
        offsets[path] = offset + data.count
        saveState()
        guard let text = String(data: data, encoding: .utf8) else { return .hookEvents(count: 0) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var relayed: [String] = []
        for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let lineData = line.data(using: .utf8),
                  var object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if let transcript = object["transcriptPath"] as? String {
                let cwd = object["cwd"] as? String
                object["transcriptPath"] = localPath(forRemote: transcript, cwd: cwd) ?? rewriter.mapPath(transcript)
            }
            if let cwd = object["cwd"] as? String {
                object["cwd"] = rewriter.mapPath(cwd)
            }
            object["timestamp"] = formatter.string(from: now())
            object["machine"] = machineName
            guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let outLine = String(data: out, encoding: .utf8) else { continue }
            relayed.append(outLine)
        }
        guard !relayed.isEmpty else { return .hookEvents(count: 0) }
        let manager = FileManager.default
        try? manager.createDirectory(atPath: localKanbanHome, withIntermediateDirectories: true)
        let payload = Data((relayed.joined(separator: "\n") + "\n").utf8)
        if !manager.fileExists(atPath: localHookEvents) {
            manager.createFile(atPath: localHookEvents, contents: payload)
        } else if let handle = FileHandle(forWritingAtPath: localHookEvents) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        }
        return .hookEvents(count: relayed.count)
    }

    // MARK: - State on disk

    private struct PersistedState: Codable {
        var offsets: [String: Int]
        var projectDirectories: [String: String]
    }

    private var statePath: String { "\(stateDirectory)/mirror.json" }

    private func saveState() {
        let state = PersistedState(offsets: offsets, projectDirectories: projectDirectories)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    /// Drops the persisted offsets, for a machine that no longer exists.
    public func forget() {
        offsets = [:]
        projectDirectories = [:]
        pending = [:]
        try? FileManager.default.removeItem(atPath: stateDirectory)
    }
}
