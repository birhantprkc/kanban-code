import Foundation

/// Everything a launch or resume needs after a machine is ready.
public struct BoxdPreparation: Sendable {
    public let machineName: String
    public let remoteHome: String
    /// Repository root on the machine.
    public let remoteProjectPath: String
    /// Directory the assistant starts in: the repository or its worktree.
    public let remoteCwd: String
    /// Local worktree created for a worktree launch, when there is one.
    public let worktree: WorktreeLink?
    /// Environment of the assistant process on the machine.
    public let extraEnv: [String: String]
    public let remoteLink: RemoteLink

    public init(machineName: String, remoteHome: String, remoteProjectPath: String, remoteCwd: String, worktree: WorktreeLink?, extraEnv: [String: String], remoteLink: RemoteLink) {
        self.machineName = machineName
        self.remoteHome = remoteHome
        self.remoteProjectPath = remoteProjectPath
        self.remoteCwd = remoteCwd
        self.worktree = worktree
        self.extraEnv = extraEnv
        self.remoteLink = remoteLink
    }
}

/// A `kanban` command from the machine, resolved to what runs on the Mac.
public struct BoxdProxyInvocation: Sendable {
    public let request: BridgeProxyRequest
    public let cardId: String?
    /// Working directory on the Mac, mapped from the machine.
    public let cwd: String?
    /// Local paths of the images the request carried.
    public let imagePaths: [String]
}

public enum BoxdSupervisorError: Error, LocalizedError, Equatable {
    case machineDestroyed(String)
    case bootstrapFailed(String)
    case initFailed(String)
    case notConnected(String)
    case noCliBundle

    public var errorDescription: String? {
        switch self {
        case .machineDestroyed(let name): "Machine \(name) no longer exists"
        case .bootstrapFailed(let message): "Could not install the kanban CLI on the machine: \(message)"
        case .initFailed(let message): "The initialization command failed: \(message)"
        case .notConnected(let name): "Machine \(name) is not connected"
        case .noCliBundle: "The kanban CLI bundle was not found in the app"
        }
    }
}

/// Runs the boxd machines behind remote cards: creates and bootstraps them,
/// keeps one bridge per running machine, mirrors their files, pauses them
/// when work stops and answers the `kanban` commands their assistants run.
public actor BoxdMachineSupervisor: RemoteMachineControl {
    public typealias Dispatch = @MainActor @Sendable (Action) -> Void
    /// Runs a proxied `kanban` command on the Mac and returns its result.
    public typealias ProxyRunner = @Sendable (BoxdProxyInvocation) async -> ShellCommand.Result
    /// True while a card on the machine is actively working.
    public typealias BusyCheck = @Sendable (String) async -> Bool

    public static let subsystem = "boxd"
    public static let defaultRemoteHome = "/home/boxd"

    private struct MachineRuntime {
        var bridge: BoxdBridge?
        var mirror: BoxdMirror
        var eventTask: Task<Void, Never>?
        var keepaliveTask: Task<Void, Never>?
        var lastActivity: Date
        var pausedReason: RemotePausedReason?
        var remoteHome: String
        var localProjectPath: String
        var remoteProjectPath: String
        var reconnectAttempts = 0
    }

    private let boxd: any BoxdPort
    public let registry: RemoteSessionRegistry
    private let settingsProvider: @Sendable () async -> BoxdSettings
    private let cliBundlePath: String?
    private let appVersion: String
    private let localHome: String
    private let localKanbanHome: String
    private var dispatch: Dispatch?
    private var proxyRunner: ProxyRunner?
    private var busyCheck: BusyCheck?
    private var machines: [String: MachineRuntime] = [:]
    private var inactivityTask: Task<Void, Never>?
    private let now: @Sendable () -> Date

    public init(
        boxd: any BoxdPort,
        registry: RemoteSessionRegistry,
        settingsProvider: @escaping @Sendable () async -> BoxdSettings,
        cliBundlePath: String?,
        appVersion: String,
        localHome: String = NSHomeDirectory(),
        localKanbanHome: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.boxd = boxd
        self.registry = registry
        self.settingsProvider = settingsProvider
        self.cliBundlePath = cliBundlePath
        self.appVersion = appVersion
        self.localHome = localHome
        self.localKanbanHome = localKanbanHome ?? "\(localHome)/.kanban-code"
        self.now = now
    }

    public func setDispatch(_ dispatch: @escaping Dispatch) {
        self.dispatch = dispatch
    }

    public func setProxyRunner(_ runner: @escaping ProxyRunner) {
        self.proxyRunner = runner
    }

    public func setBusyCheck(_ check: @escaping BusyCheck) {
        self.busyCheck = check
    }

    // MARK: - Queries

    public func isConnected(_ machineName: String) -> Bool {
        registry.state(of: machineName)?.isConnected == true
    }

    public func bridge(for machineName: String) -> BoxdBridge? {
        machines[machineName]?.bridge
    }

    public func mirror(for machineName: String) -> BoxdMirror? {
        machines[machineName]?.mirror
    }

    public func lastActivity(of machineName: String) -> Date? {
        machines[machineName]?.lastActivity
    }

    /// Command the embedded terminal runs to attach to a remote tmux session.
    public nonisolated static func attachCommand(boxdPath: String, machineName: String, sessionName: String) -> String {
        "\(shellEscape(boxdPath)) machine exec --tty \(shellEscape(machineName)) -- tmux attach -t \(shellEscape(sessionName))"
    }

    // MARK: - Startup

    /// Re-seeds the registry from persisted links and reconnects the
    /// machines that are running. Paused machines stay paused.
    public func restore(links: [Link]) async {
        registry.seed(from: links)
        var seen: Set<String> = []
        for link in links {
            guard let remote = link.remote, remote.mode == .boxd, !seen.contains(remote.machineName) else { continue }
            seen.insert(remote.machineName)
            let projectPath = link.projectPath ?? localHome
            do {
                let machine = try await boxd.getMachine(name: remote.machineName)
                switch machine.status {
                case .running, .booting:
                    try await connect(
                        machineName: remote.machineName,
                        localProjectPath: projectPath,
                        remoteProjectPath: remote.remoteProjectPath,
                        remoteHome: remote.remoteHome ?? Self.defaultRemoteHome
                    )
                case .destroyed:
                    await report(remote.machineName, state: .destroyed)
                default:
                    let reason = remote.pausedReason ?? .manual
                    machines[remote.machineName] = makeRuntime(
                        machineName: remote.machineName,
                        localProjectPath: projectPath,
                        remoteProjectPath: remote.remoteProjectPath,
                        remoteHome: remote.remoteHome ?? Self.defaultRemoteHome,
                        pausedReason: reason
                    )
                    await report(remote.machineName, state: .paused(reason))
                }
            } catch {
                KanbanCodeLog.warn(Self.subsystem, "restore \(remote.machineName): \(error.localizedDescription)")
                await report(remote.machineName, state: .unreachable)
            }
        }
        startInactivityTimer()
    }

    // MARK: - Prepare a launch or a resume

    /// Brings a machine up for a card and prepares the checkout on it.
    ///
    /// - `existingMachine`: the machine the card already has, or another
    ///   machine the user picked. Nil creates a new machine from the snapshot.
    /// - `worktreeName`: the worktree to create locally and on the machine.
    /// - `sessionNames`: tmux names the card will use, registered as remote
    ///   before anything runs.
    public func prepare(
        cardId: String,
        localProjectPath: String,
        existingMachine: String?,
        worktreeName: String?,
        existingWorktree: WorktreeLink?,
        sessionNames: [String],
        runInit: Bool = true,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> BoxdPreparation {
        let settings = await settingsProvider()
        let repoRoot = Self.repositoryRoot(of: localProjectPath)
        let originURL = await Self.originURL(of: repoRoot)
        let repoName = BoxdLaunchPlanner.repoName(fromOriginURL: originURL, fallbackFolder: (repoRoot as NSString).lastPathComponent)
        let machineName = existingMachine ?? BoxdLaunchPlanner.machineName(repoName: repoName, cardId: cardId)
        let remoteHome = machines[machineName]?.remoteHome ?? Self.defaultRemoteHome
        let remoteProjectPath = BoxdLaunchPlanner.remoteProjectPath(
            folderTemplate: settings.folderTemplate, repoName: repoName, remoteHome: remoteHome)

        for name in sessionNames { registry.assign(sessionName: name, to: machineName) }
        await report(machineName, state: .connecting)

        log("Preparing machine \(machineName)")
        let machine = try await ensureRunning(machineName: machineName, settings: settings, log: log)
        try await connect(
            machineName: machineName,
            localProjectPath: repoRoot,
            remoteProjectPath: remoteProjectPath,
            remoteHome: remoteHome,
            log: log
        )
        guard let bridge = machines[machineName]?.bridge else { throw BoxdSupervisorError.notConnected(machineName) }

        // Local worktree first: the branch has to exist on origin before the
        // machine can check it out.
        var worktree = existingWorktree
        var branch = existingWorktree?.branch
        if let worktreeName, worktree == nil {
            log("Creating worktree \(worktreeName)")
            worktree = try await Self.createLocalWorktree(repoRoot: repoRoot, name: worktreeName)
            branch = worktree?.branch
        }
        if let branch {
            await Self.pushBranchIfNeeded(repoRoot: repoRoot, branch: branch, log: log)
        }

        if runInit {
            log("Running the initialization command")
            let localBranch = await Self.currentBranch(of: repoRoot)
            let script = BoxdLaunchPlanner.initScript(
                template: settings.initCommand,
                repoDir: remoteProjectPath,
                repoURL: originURL ?? "",
                repoName: repoName,
                branch: branch ?? localBranch ?? "main"
            )
            let result = try await bridge.exec(["bash", "-lc", script], stdin: nil, cwd: remoteHome, timeout: 900)
            if !result.stdout.isEmpty { log(result.stdout.trimmingCharacters(in: .newlines)) }
            if !result.succeeded {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                throw BoxdSupervisorError.initFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        var remoteCwd = remoteProjectPath
        if let worktree, let branch = worktree.branch {
            let remoteWorktree = "\(remoteProjectPath)/.claude/worktrees/\((worktree.path as NSString).lastPathComponent)"
            log("Checking out \(branch) on the machine")
            let script = Self.remoteWorktreeScript(repo: remoteProjectPath, worktreePath: remoteWorktree, branch: branch)
            let result = try await bridge.exec(["bash", "-lc", script], stdin: nil, cwd: remoteHome, timeout: 300)
            if !result.succeeded {
                throw BoxdSupervisorError.initFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            remoteCwd = remoteWorktree
        }

        // Claude asks whether a folder is trusted the first time it starts
        // there, and that question would swallow the first prompt. The user
        // trusts the repository they configured, so the answer is recorded
        // before the assistant starts.
        try await trustClaudeFolders([remoteProjectPath, remoteCwd], bridge: bridge, remoteHome: remoteHome)

        // Files that never reach git, like .env, go over the bridge.
        let matches = BoxdLaunchPlanner.copyMatches(globs: settings.copyGlobs, projectRoot: repoRoot)
        if !matches.isEmpty { log("Copying \(matches.count) file(s)") }
        for relative in matches {
            guard let data = FileManager.default.contents(atPath: "\(repoRoot)/\(relative)") else { continue }
            try await bridge.put(path: "\(remoteProjectPath)/\(relative)", data: data, mode: nil)
            if remoteCwd != remoteProjectPath {
                try await bridge.put(path: "\(remoteCwd)/\(relative)", data: data, mode: nil)
            }
        }

        let remoteLink = RemoteLink(
            mode: .boxd,
            machineName: machineName,
            machineId: machine.id,
            remoteProjectPath: remoteProjectPath,
            remoteCwd: remoteCwd,
            remoteHome: remoteHome,
            lastStatus: "running"
        )
        await dispatch?(.remoteMachineAssigned(cardId: cardId, remote: remoteLink))
        touch(machineName)

        return BoxdPreparation(
            machineName: machineName,
            remoteHome: remoteHome,
            remoteProjectPath: remoteProjectPath,
            remoteCwd: remoteCwd,
            worktree: worktree,
            extraEnv: Self.sessionEnvironment(cardId: cardId, remoteHome: remoteHome),
            remoteLink: remoteLink
        )
    }

    /// Marks folders as trusted in the machine's `~/.claude.json`.
    private func trustClaudeFolders(_ folders: [String], bridge: BoxdBridge, remoteHome: String) async throws {
        let unique = Array(Set(folders)).sorted()
        let script = Self.trustFoldersScript(folders: unique, claudeConfigPath: "\(remoteHome)/.claude.json")
        let result = try await bridge.exec(["/usr/local/bin/node", "-e", script], stdin: nil, cwd: remoteHome, timeout: 30)
        if !result.succeeded {
            KanbanCodeLog.warn(Self.subsystem, "could not mark folders trusted: \(result.stderr)")
        }
    }

    /// Node script that sets `hasTrustDialogAccepted` for each folder in
    /// `~/.claude.json`, skips the renderer question, and sets
    /// `skipDangerousModePermissionPrompt` in `~/.claude/settings.json`, which
    /// is what silences the bypass permissions question. Each of these
    /// questions blocks the first prompt on a fresh machine.
    nonisolated static func trustFoldersScript(folders: [String], claudeConfigPath: String) -> String {
        let foldersJSON = (try? JSONSerialization.data(withJSONObject: folders)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let pathJSON = (try? JSONSerialization.data(withJSONObject: [claudeConfigPath])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        const fs = require('fs');
        const file = \(pathJSON)[0];
        let config = {};
        try { config = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) {}
        config.projects = config.projects || {};
        config.bypassPermissionsModeAccepted = true;
        config.fullscreenUpsellSeenCount = Math.max(config.fullscreenUpsellSeenCount || 0, 3);
        for (const folder of \(foldersJSON)) {
          const entry = config.projects[folder] || {};
          entry.hasTrustDialogAccepted = true;
          config.projects[folder] = entry;
        }
        fs.writeFileSync(file, JSON.stringify(config, null, 2));
        const settingsFile = require('path').join(require('path').dirname(file), '.claude', 'settings.json');
        let settings = {};
        try { settings = JSON.parse(fs.readFileSync(settingsFile, 'utf8')); } catch (e) {}
        settings.skipDangerousModePermissionPrompt = true;
        fs.mkdirSync(require('path').dirname(settingsFile), { recursive: true });
        fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2));
        """
    }

    /// Environment every assistant process gets on the machine.
    public nonisolated static func sessionEnvironment(cardId: String, remoteHome: String) -> [String: String] {
        [
            "KANBAN_REMOTE_PROXY": "1",
            "KANBAN_CARD_ID": cardId,
            "KANBAN_CODE_HOME": "\(remoteHome)/.kanban-code",
        ]
    }

    /// Makes the session environment visible to every pane of the tmux
    /// session, not only the first command.
    public func exportSessionEnvironment(machineName: String, sessionName: String, env: [String: String]) async {
        guard let bridge = machines[machineName]?.bridge else { return }
        for (key, value) in env {
            _ = try? await bridge.exec(["tmux", "set-environment", "-t", sessionName, key, value], stdin: nil, cwd: nil, timeout: 20)
        }
    }

    /// Forgets the machine of these tmux names, so they route locally again.
    public func releaseSessions(_ sessionNames: [String]) {
        for name in sessionNames { registry.unassign(sessionName: name) }
    }

    /// Whether the tmux session of a card is still alive on its machine.
    public func hasSession(machineName: String, sessionName: String) async -> Bool {
        guard let bridge = machines[machineName]?.bridge else { return false }
        let result = try? await bridge.exec(["tmux", "has-session", "-t", sessionName], stdin: nil, cwd: nil, timeout: 20)
        let alive = result?.succeeded == true
        if !alive { registry.forgetSession(sessionName, on: machineName) }
        return alive
    }

    /// Copies a local transcript to the machine, rewritten to machine paths,
    /// together with its sidecar directory and statusline context.
    public func pushTranscript(
        machineName: String,
        localPath: String,
        sessionId: String,
        remoteCwd: String
    ) async throws {
        guard let runtime = machines[machineName], let bridge = runtime.bridge else {
            throw BoxdSupervisorError.notConnected(machineName)
        }
        let mirror = runtime.mirror
        guard let remotePath = await mirror.remotePath(forLocal: localPath, remoteCwd: remoteCwd) else { return }
        let reversed = await mirror.rewriter.reversed
        let temporary = (NSTemporaryDirectory() as NSString).appendingPathComponent("kanban-push-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        try reversed.rewriteFile(at: localPath, to: temporary)
        let data = try Data(contentsOf: URL(fileURLWithPath: temporary))
        await mirror.suspend(remotePath: remotePath)
        defer { Task { await mirror.resume(remotePath: remotePath) } }
        try await upload(machineName: machineName, bridge: bridge, remotePath: remotePath, data: data)
        await mirror.recordPushed(
            remotePath: remotePath,
            bytes: data.count,
            localProjectDirectory: (localPath as NSString).deletingLastPathComponent
        )

        let localSidecar = ((localPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(sessionId)
        let remoteSidecar = ((remotePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(sessionId)
        if let enumerator = FileManager.default.enumerator(atPath: localSidecar) {
            let entries = enumerator.allObjects.compactMap { $0 as? String }
            for relative in entries {
                let path = "\(localSidecar)/\(relative)"
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      let bytes = FileManager.default.contents(atPath: path) else { continue }
                let payload = path.hasSuffix(".jsonl") ? Self.rewrite(bytes, with: reversed) : bytes
                let target = "\(remoteSidecar)/\(relative)"
                try await upload(machineName: machineName, bridge: bridge, remotePath: target, data: payload)
                await mirror.recordPushed(remotePath: target, bytes: payload.count)
            }
        }

        let localContext = "\(localKanbanHome)/context/\(sessionId).json"
        if let bytes = FileManager.default.contents(atPath: localContext) {
            let target = "\(runtime.remoteHome)/.kanban-code/context/\(sessionId).json"
            try await upload(machineName: machineName, bridge: bridge, remotePath: target, data: bytes)
            await mirror.recordPushed(remotePath: target, bytes: bytes.count)
        }
    }

    /// Size of a transcript on the machine, or zero when it is not there.
    public func remoteTranscriptSize(machineName: String, localPath: String, remoteCwd: String) async -> Int {
        guard let runtime = machines[machineName], let bridge = runtime.bridge,
              let remotePath = await runtime.mirror.remotePath(forLocal: localPath, remoteCwd: remoteCwd) else { return 0 }
        let result = try? await bridge.exec(["stat", "-c", "%s", remotePath], stdin: nil, cwd: nil, timeout: 20)
        return Int(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    // MARK: - RemoteMachineControl

    public func pause(machineName: String, reason: RemotePausedReason) async {
        guard var runtime = machines[machineName] else {
            try? await boxd.pause(name: machineName)
            await report(machineName, state: .paused(reason))
            return
        }
        runtime.pausedReason = reason
        runtime.eventTask?.cancel()
        runtime.keepaliveTask?.cancel()
        runtime.eventTask = nil
        runtime.keepaliveTask = nil
        if let bridge = runtime.bridge {
            await bridge.stop()
        }
        runtime.bridge = nil
        machines[machineName] = runtime
        registry.disconnectMachine(machineName, state: .paused(reason))
        do {
            try await boxd.pause(name: machineName)
            KanbanCodeLog.info(Self.subsystem, "\(machineName): paused (\(reason.rawValue))")
        } catch {
            KanbanCodeLog.warn(Self.subsystem, "\(machineName): pause failed: \(error.localizedDescription)")
        }
        await report(machineName, state: .paused(reason))
    }

    public func destroy(machineName: String) async throws {
        if var runtime = machines[machineName] {
            runtime.eventTask?.cancel()
            runtime.keepaliveTask?.cancel()
            if let bridge = runtime.bridge { await bridge.stop() }
            runtime.bridge = nil
            await runtime.mirror.forget()
            machines[machineName] = nil
        }
        registry.removeMachine(machineName)
        do {
            try await boxd.remove(name: machineName)
        } catch let error as BoxdError {
            // A machine that is already gone is the state we want.
            if case .commandFailed(_, _, let message) = error, message.lowercased().contains("not found") {
                KanbanCodeLog.info(Self.subsystem, "\(machineName): already removed")
            } else {
                throw error
            }
        }
        KanbanCodeLog.info(Self.subsystem, "\(machineName): destroyed")
    }

    /// Pauses every running machine, in parallel, within `deadline`.
    public func pauseAll(reason: RemotePausedReason, deadline: Duration = .seconds(8)) async {
        let running = machines.filter { $0.value.bridge != nil }.map(\.key)
        guard !running.isEmpty else { return }
        await withTaskGroup(of: Bool.self) { group in
            for name in running {
                group.addTask {
                    await self.pause(machineName: name, reason: reason)
                    return true
                }
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            var paused = 0
            for await done in group {
                if !done { break }
                paused += 1
                if paused == running.count { break }
            }
            group.cancelAll()
        }
    }

    /// Machines paused for system sleep come back after wake.
    public func resumeAfterSleep() async {
        for (name, runtime) in machines where runtime.pausedReason == .systemSleep {
            do {
                _ = try await ensureRunning(machineName: name, settings: await settingsProvider(), log: { _ in })
                try await connect(
                    machineName: name,
                    localProjectPath: runtime.localProjectPath,
                    remoteProjectPath: runtime.remoteProjectPath,
                    remoteHome: runtime.remoteHome
                )
            } catch {
                KanbanCodeLog.warn(Self.subsystem, "\(name): wake failed: \(error.localizedDescription)")
                await report(name, state: .unreachable)
            }
        }
    }

    /// Names of machines with an open bridge.
    public var connectedMachines: [String] {
        machines.filter { $0.value.bridge != nil }.map(\.key).sorted()
    }

    // MARK: - Machine lifecycle

    private func ensureRunning(machineName: String, settings: BoxdSettings, log: @escaping @Sendable (String) -> Void) async throws -> BoxdMachine {
        var machine: BoxdMachine
        do {
            machine = try await boxd.getMachine(name: machineName)
        } catch {
            log("Creating machine \(machineName) from snapshot \(settings.snapshotName)")
            machine = try await boxd.createMachine(
                name: machineName,
                snapshot: settings.snapshotName.isEmpty ? nil : settings.snapshotName,
                autoSuspendSeconds: settings.inactivityTimeoutSeconds
            )
            KanbanCodeLog.info(Self.subsystem, "\(machineName): created from \(settings.snapshotName)")
            machine = try await waitUntilRunning(machineName: machineName, fallback: machine)
            return machine
        }
        switch machine.status {
        case .running:
            return machine
        case .standby:
            log("Resuming machine \(machineName)")
            try await boxd.resume(name: machineName)
        case .hibernated:
            log("Waking machine \(machineName)")
            try await boxd.wake(name: machineName)
        case .stopped, .unknown:
            log("Starting machine \(machineName)")
            try await boxd.start(name: machineName)
        case .booting, .stopping:
            break
        case .destroyed:
            await report(machineName, state: .destroyed)
            throw BoxdSupervisorError.machineDestroyed(machineName)
        }
        return try await waitUntilRunning(machineName: machineName, fallback: machine)
    }

    private func waitUntilRunning(machineName: String, fallback: BoxdMachine) async throws -> BoxdMachine {
        var latest = fallback
        for _ in 0..<60 {
            if let machine = try? await boxd.getMachine(name: machineName) {
                latest = machine
                if machine.status == .running { return machine }
                if machine.status == .destroyed { throw BoxdSupervisorError.machineDestroyed(machineName) }
            }
            try await Task.sleep(for: .seconds(2))
        }
        return latest
    }

    private func makeRuntime(machineName: String, localProjectPath: String, remoteProjectPath: String?, remoteHome: String, pausedReason: RemotePausedReason? = nil) -> MachineRuntime {
        let mappings = BoxdLaunchPlanner.mappings(
            localProjectPath: localProjectPath,
            remoteProjectPath: remoteProjectPath ?? "\(remoteHome)/\((localProjectPath as NSString).lastPathComponent)",
            localHome: localHome,
            remoteHome: remoteHome,
            localKanbanHome: localKanbanHome,
            remoteKanbanHome: "\(remoteHome)/.kanban-code"
        )
        let mirror = BoxdMirror(
            machineName: machineName,
            rewriter: TranscriptPathRewriter(mappings),
            remoteHome: remoteHome,
            localHome: localHome,
            localKanbanHome: localKanbanHome
        )
        return MachineRuntime(
            bridge: nil,
            mirror: mirror,
            lastActivity: now(),
            pausedReason: pausedReason,
            remoteHome: remoteHome,
            localProjectPath: localProjectPath,
            remoteProjectPath: remoteProjectPath ?? "\(remoteHome)/\((localProjectPath as NSString).lastPathComponent)"
        )
    }

    /// Opens the bridge to a running machine, installing the CLI first when
    /// the machine does not have this app's version of it.
    private func connect(
        machineName: String,
        localProjectPath: String,
        remoteProjectPath: String?,
        remoteHome: String,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        if machines[machineName]?.bridge != nil { return }
        var runtime = machines[machineName] ?? makeRuntime(
            machineName: machineName, localProjectPath: localProjectPath,
            remoteProjectPath: remoteProjectPath, remoteHome: remoteHome)
        if let remoteProjectPath, runtime.remoteProjectPath != remoteProjectPath || runtime.localProjectPath != localProjectPath {
            runtime = makeRuntime(machineName: machineName, localProjectPath: localProjectPath, remoteProjectPath: remoteProjectPath, remoteHome: remoteHome, pausedReason: runtime.pausedReason)
        }
        runtime.pausedReason = nil
        machines[machineName] = runtime

        try await bootstrapIfNeeded(machineName: machineName, remoteHome: remoteHome, log: log)

        log("Connecting to \(machineName)")
        let bridge = try BoxdBridge.spawn(machineName: machineName, remoteHome: remoteHome)
        try await bridge.start()
        runtime.bridge = bridge
        runtime.lastActivity = now()
        runtime.reconnectAttempts = 0
        if let home = await bridge.remoteHome, !home.isEmpty, !home.hasSuffix("/.kanban-code"), home != runtime.remoteHome {
            runtime = makeRuntime(machineName: machineName, localProjectPath: localProjectPath, remoteProjectPath: remoteProjectPath, remoteHome: home)
            runtime.bridge = bridge
        }
        machines[machineName] = runtime

        let mirror = runtime.mirror
        if await mirror.offsets.isEmpty {
            // First contact: what the snapshot brought along stays there.
            let sizes = await existingFileSizes(bridge: bridge, mirror: mirror)
            await mirror.seedOffsets(sizes)
        }
        try await bridge.watch(roots: await mirror.watchRoots, offsets: await mirror.offsets)

        let transport = BridgeTmuxTransport(runner: bridge, remoteHome: runtime.remoteHome)
        registry.setMachine(machineName, state: .connected, tmux: TmuxAdapter(transport: transport))
        await report(machineName, state: .connected)
        KanbanCodeLog.info(Self.subsystem, "\(machineName): connected (agent \(await bridge.agentVersion ?? "?"))")

        runtime.eventTask = Task { [weak self] in
            for await event in bridge.events {
                await self?.handle(event, from: machineName)
            }
        }
        runtime.keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self else { return }
                if !(await self.isConnected(machineName)) { return }
                try? await bridge.ping()
            }
        }
        machines[machineName] = runtime
        startInactivityTimer()
    }

    private func existingFileSizes(bridge: BoxdBridge, mirror: BoxdMirror) async -> [String: Int] {
        let roots = await mirror.watchRoots.map(\.path)
        let script = "for r in " + roots.map(Self.shellEscape).joined(separator: " ")
            + "; do [ -e \"$r\" ] && find \"$r\" -type f -printf '%s %p\\n'; done; true"
        guard let result = try? await bridge.exec(["bash", "-c", script], stdin: nil, cwd: nil, timeout: 60) else { return [:] }
        var sizes: [String: Int] = [:]
        for line in result.stdout.components(separatedBy: "\n") {
            guard let space = line.firstIndex(of: " "), let size = Int(line[..<space]) else { continue }
            sizes[String(line[line.index(after: space)...])] = size
        }
        return sizes
    }

    private func bootstrapIfNeeded(machineName: String, remoteHome: String, log: @escaping @Sendable (String) -> Void) async throws {
        let versionFile = "\(remoteHome)/.kanban-code/cli/VERSION"
        let installed = (try? await boxd.exec(name: machineName, command: "cat \(versionFile) 2>/dev/null; true", timeout: 60))?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if installed == appVersion, !appVersion.isEmpty { return }
        guard let cliBundlePath, FileManager.default.fileExists(atPath: "\(cliBundlePath)/dist/kanban.js") else {
            throw BoxdSupervisorError.noCliBundle
        }
        log("Installing the kanban CLI \(appVersion) on \(machineName)")
        let archive = (NSTemporaryDirectory() as NSString).appendingPathComponent("kanban-cli-\(UUID().uuidString).tgz")
        defer { try? FileManager.default.removeItem(atPath: archive) }
        // COPYFILE_DISABLE keeps macOS extended attributes out of the archive;
        // GNU tar on the machine would print a warning for every file.
        var tarEnvironment = ShellCommand.loginEnvironment
        tarEnvironment["COPYFILE_DISABLE"] = "1"
        let tar = try await ShellCommand.run(
            "/usr/bin/tar",
            arguments: ["--no-xattrs", "-czf", archive, "-C", (cliBundlePath as NSString).deletingLastPathComponent, (cliBundlePath as NSString).lastPathComponent],
            environment: tarEnvironment,
            timeout: 300
        )
        guard tar.succeeded, let data = FileManager.default.contents(atPath: archive) else {
            throw BoxdSupervisorError.bootstrapFailed(tar.stderr)
        }
        try await boxd.upload(name: machineName, remotePath: "/tmp/kanban-cli.tgz", data: data)
        let bundleName = (cliBundlePath as NSString).lastPathComponent
        let script = """
        set -e
        mkdir -p \(remoteHome)/.kanban-code \(remoteHome)/.local/bin
        rm -rf \(remoteHome)/.kanban-code/cli.new
        mkdir -p \(remoteHome)/.kanban-code/cli.new
        tar -xzf /tmp/kanban-cli.tgz -C \(remoteHome)/.kanban-code/cli.new --strip-components=1 \(Self.shellEscape(bundleName))
        rm -rf \(remoteHome)/.kanban-code/cli
        mv \(remoteHome)/.kanban-code/cli.new \(remoteHome)/.kanban-code/cli
        rm -f /tmp/kanban-cli.tgz
        printf '%s' \(Self.shellEscape(appVersion)) > \(versionFile)
        printf '#!/bin/sh\\nexec /usr/local/bin/node \(remoteHome)/.kanban-code/cli/dist/kanban.js "$@"\\n' > \(remoteHome)/.local/bin/kanban
        chmod +x \(remoteHome)/.local/bin/kanban
        KANBAN_CODE_HOME=\(remoteHome)/.kanban-code \(remoteHome)/.local/bin/kanban hooks install
        """
        let result = try await boxd.exec(name: machineName, command: "bash -c \(Self.shellEscape(script))", timeout: 300)
        guard result.succeeded else {
            throw BoxdSupervisorError.bootstrapFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        KanbanCodeLog.info(Self.subsystem, "\(machineName): kanban CLI \(appVersion) installed")
    }

    // MARK: - Events

    private func handle(_ event: BridgeEvent, from machineName: String) async {
        guard let runtime = machines[machineName] else { return }
        switch event {
        case .file, .removed:
            let outcome = await runtime.mirror.apply(event)
            if case .transcript = outcome { touch(machineName) }
            if case .hookEvents(let count) = outcome, count > 0 { touch(machineName) }
        case .activity:
            touch(machineName)
        case .proxy(let request):
            await runProxy(request, on: machineName)
        case .hello:
            break
        case .disconnected(let reason):
            await handleDisconnect(machineName: machineName, reason: reason)
        }
    }

    private func touch(_ machineName: String) {
        machines[machineName]?.lastActivity = now()
    }

    private func handleDisconnect(machineName: String, reason: String) async {
        guard var runtime = machines[machineName] else { return }
        runtime.bridge = nil
        runtime.keepaliveTask?.cancel()
        runtime.keepaliveTask = nil
        machines[machineName] = runtime
        if let paused = runtime.pausedReason {
            registry.disconnectMachine(machineName, state: .paused(paused))
            return
        }
        registry.disconnectMachine(machineName, state: .unreachable)
        await report(machineName, state: .unreachable)
        KanbanCodeLog.warn(Self.subsystem, "\(machineName): bridge lost (\(reason)), reconnecting")
        Task { [weak self] in await self?.reconnect(machineName: machineName) }
    }

    private func reconnect(machineName: String) async {
        guard var runtime = machines[machineName], runtime.bridge == nil, runtime.pausedReason == nil else { return }
        runtime.reconnectAttempts += 1
        machines[machineName] = runtime
        let attempt = runtime.reconnectAttempts
        guard attempt <= 6 else {
            KanbanCodeLog.warn(Self.subsystem, "\(machineName): giving up after \(attempt - 1) reconnect attempts")
            return
        }
        try? await Task.sleep(for: .seconds(min(60, 5 * attempt)))
        guard let current = machines[machineName], current.bridge == nil, current.pausedReason == nil else { return }
        do {
            let machine = try await boxd.getMachine(name: machineName)
            switch machine.status {
            case .running, .booting:
                try await connect(
                    machineName: machineName,
                    localProjectPath: current.localProjectPath,
                    remoteProjectPath: current.remoteProjectPath,
                    remoteHome: current.remoteHome
                )
            case .standby, .hibernated, .stopped:
                // boxd paused it on its own (auto-suspend): keep it that way.
                machines[machineName]?.pausedReason = .inactivity
                registry.disconnectMachine(machineName, state: .paused(.inactivity))
                await report(machineName, state: .paused(.inactivity))
            case .destroyed:
                machines[machineName] = nil
                registry.removeMachine(machineName)
                await report(machineName, state: .destroyed)
            case .stopping, .unknown:
                Task { [weak self] in await self?.reconnect(machineName: machineName) }
            }
        } catch {
            KanbanCodeLog.warn(Self.subsystem, "\(machineName): reconnect \(attempt) failed: \(error.localizedDescription)")
            Task { [weak self] in await self?.reconnect(machineName: machineName) }
        }
    }

    private func runProxy(_ request: BridgeProxyRequest, on machineName: String) async {
        guard let runtime = machines[machineName], let bridge = runtime.bridge else { return }
        touch(machineName)
        let rewriter = await runtime.mirror.rewriter
        var imagePaths: [String] = []
        if !request.images.isEmpty {
            let directory = "\(localKanbanHome)/images/proxy/\(request.id)"
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for image in request.images {
                let path = "\(directory)/\((image.name as NSString).lastPathComponent)"
                try? image.data.write(to: URL(fileURLWithPath: path))
                imagePaths.append(path)
            }
        }
        let invocation = BoxdProxyInvocation(
            request: request,
            cardId: request.env["KANBAN_CARD_ID"],
            cwd: request.cwd.map { rewriter.mapPath($0) },
            imagePaths: imagePaths
        )
        let result: ShellCommand.Result
        if let proxyRunner {
            result = await proxyRunner(invocation)
        } else {
            result = ShellCommand.Result(exitCode: 1, stdout: "", stderr: "kanban proxy is not available in this app")
        }
        do {
            try await bridge.reply(to: request, stdout: result.stdout, stderr: result.stderr, code: result.exitCode)
        } catch {
            KanbanCodeLog.warn(Self.subsystem, "\(machineName): could not answer proxy \(request.id): \(error.localizedDescription)")
        }
    }

    // MARK: - Inactivity

    private func startInactivityTimer() {
        guard inactivityTask == nil else { return }
        inactivityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.checkInactivity()
            }
        }
    }

    /// Pauses machines that had no activity for the configured timeout.
    public func checkInactivity() async {
        let timeout = TimeInterval(await settingsProvider().inactivityTimeoutSeconds)
        let current = now()
        for (name, runtime) in machines where runtime.bridge != nil {
            guard current.timeIntervalSince(runtime.lastActivity) > timeout else { continue }
            if let busyCheck, await busyCheck(name) {
                touch(name)
                continue
            }
            KanbanCodeLog.info(Self.subsystem, "\(name): no activity for \(Int(timeout))s, pausing")
            await pause(machineName: name, reason: .inactivity)
        }
    }

    // MARK: - Reporting

    private func report(_ machineName: String, state: RemoteMachineState) async {
        if registry.state(of: machineName) != state, state != .connected {
            registry.setMachine(machineName, state: state)
        }
        await dispatch?(.remoteMachineStateChanged(machineName: machineName, state: state))
    }

    // MARK: - Uploads

    /// Small payloads ride the bridge; large ones go through `boxd machine cp`
    /// so one JSON line never carries megabytes.
    private func upload(machineName: String, bridge: BoxdBridge, remotePath: String, data: Data) async throws {
        if data.count <= 2 * 1024 * 1024 {
            try await bridge.put(path: remotePath, data: data, mode: nil)
        } else {
            _ = try await bridge.exec(["mkdir", "-p", (remotePath as NSString).deletingLastPathComponent], stdin: nil, cwd: nil, timeout: 20)
            try await boxd.upload(name: machineName, remotePath: remotePath, data: data)
        }
    }

    private nonisolated static func rewrite(_ data: Data, with rewriter: TranscriptPathRewriter) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }
        return Data((lines.map(rewriter.rewriteLine).joined(separator: "\n") + (endsWithNewline ? "\n" : "")).utf8)
    }

    // MARK: - Git helpers

    /// The repository root of a path, walking up out of a worktree.
    public nonisolated static func repositoryRoot(of path: String) -> String {
        if let range = path.range(of: "/.claude/worktrees/") {
            return String(path[..<range.lowerBound])
        }
        return path
    }

    private nonisolated static func git(_ arguments: [String], in directory: String) async -> ShellCommand.Result? {
        let gitPath = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
        return try? await ShellCommand.run(gitPath, arguments: arguments, currentDirectory: directory, timeout: 120)
    }

    nonisolated static func originURL(of repoRoot: String) async -> String? {
        guard let result = await git(["remote", "get-url", "origin"], in: repoRoot), result.succeeded else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    nonisolated static func currentBranch(of repoRoot: String) async -> String? {
        guard let result = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot), result.succeeded else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    /// Creates `<repo>/.claude/worktrees/<name>` on a new branch, the same
    /// layout Claude Code's `--worktree` uses.
    nonisolated static func createLocalWorktree(repoRoot: String, name: String) async throws -> WorktreeLink {
        let path = "\(repoRoot)/.claude/worktrees/\(name)"
        if FileManager.default.fileExists(atPath: path) {
            let branch = await currentBranch(of: path) ?? name
            return WorktreeLink(path: path, branch: branch)
        }
        try? FileManager.default.createDirectory(atPath: "\(repoRoot)/.claude/worktrees", withIntermediateDirectories: true)
        let branchExists = (await git(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: repoRoot))?.succeeded == true
        let arguments = branchExists ? ["worktree", "add", path, name] : ["worktree", "add", "-b", name, path]
        guard let result = await git(arguments, in: repoRoot), result.succeeded else {
            throw WorktreeError.createFailed(name: name, message: (await git(arguments, in: repoRoot))?.stderr ?? "git failed")
        }
        return WorktreeLink(path: path, branch: name)
    }

    nonisolated static func pushBranchIfNeeded(repoRoot: String, branch: String, log: @escaping @Sendable (String) -> Void) async {
        let upstream = await git(["rev-parse", "--abbrev-ref", "\(branch)@{upstream}"], in: repoRoot)
        if upstream?.succeeded == true { return }
        log("Pushing \(branch) to origin")
        let result = await git(["push", "-u", "origin", branch], in: repoRoot)
        if result?.succeeded != true {
            KanbanCodeLog.warn(subsystem, "push \(branch) failed: \(result?.stderr ?? "git failed")")
        }
    }

    nonisolated static func remoteWorktreeScript(repo: String, worktreePath: String, branch: String) -> String {
        let repoQ = shellEscape(repo)
        let worktreeQ = shellEscape(worktreePath)
        let branchQ = shellEscape(branch)
        return """
        set -e
        cd \(repoQ)
        git fetch origin \(branchQ) || true
        if [ ! -d \(worktreeQ) ]; then
          mkdir -p "$(dirname \(worktreeQ))"
          if git show-ref --verify --quiet refs/heads/\(branchQ); then
            git worktree add \(worktreeQ) \(branchQ)
          elif git show-ref --verify --quiet refs/remotes/origin/\(branchQ); then
            git worktree add --track -b \(branchQ) \(worktreeQ) origin/\(branchQ)
          else
            git worktree add -b \(branchQ) \(worktreeQ)
          fi
        else
          cd \(worktreeQ) && git pull --ff-only || true
        fi
        """
    }

    nonisolated static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
