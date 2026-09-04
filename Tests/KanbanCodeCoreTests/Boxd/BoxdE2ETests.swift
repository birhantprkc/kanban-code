import Testing
import Foundation
@testable import KanbanCodeCore

/// Round trip against a real boxd machine. Runs only with `KANBAN_BOXD_E2E=1`
/// because it creates a machine from the configured snapshot, starts Claude
/// on it, and destroys the machine at the end. Everything the Mac side
/// writes goes to a temporary home, so the real board is not touched.
///
///     KANBAN_BOXD_E2E=1 swift test --filter BoxdE2E
@Suite("Boxd end to end", .serialized, .enabled(if: ProcessInfo.processInfo.environment["KANBAN_BOXD_E2E"] == "1"))
struct BoxdE2ETests {

    private static let cardId = "card_e2e" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    private static let repoURL = "https://github.com/langwatch/kanban-code.git"

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [Action] = []
        private var proxied: [BoxdProxyInvocation] = []
        func add(_ action: Action) { lock.lock(); actions.append(action); lock.unlock() }
        func add(_ invocation: BoxdProxyInvocation) { lock.lock(); proxied.append(invocation); lock.unlock() }
        private var lines: [String] = []
        func log(_ line: String) { lock.lock(); lines.append(line); lock.unlock(); print("[e2e] \(line)") }
        var logText: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
        var states: [(String, RemoteMachineState)] {
            lock.lock(); defer { lock.unlock() }
            return actions.compactMap {
                if case .remoteMachineStateChanged(let name, let state) = $0 { return (name, state) }
                return nil
            }
        }
        var proxyRequests: [BoxdProxyInvocation] { lock.lock(); defer { lock.unlock() }; return proxied }
    }

    @Test("create, bootstrap, launch claude, mirror, proxy, pause, resume, destroy")
    func roundTrip() async throws {
        let boxd = BoxdCliAdapter()
        try #require(await boxd.isAvailable(), "boxd CLI not installed")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cliBundle = root.appendingPathComponent("cli").path
        try #require(FileManager.default.fileExists(atPath: "\(cliBundle)/dist/kanban.js"), "run `cd cli && pnpm run build` first")

        let home = NSTemporaryDirectory() + "kanban-boxd-e2e-\(UUID().uuidString)"
        let project = "\(home)/Projects/kanban-code"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let git = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
        _ = try await ShellCommand.run(git, arguments: ["init", "-q", "-b", "main"], currentDirectory: project)
        _ = try await ShellCommand.run(git, arguments: ["remote", "add", "origin", Self.repoURL], currentDirectory: project)
        try "E2E_SECRET=copied-from-mac\n".write(toFile: "\(project)/.env", atomically: true, encoding: .utf8)

        let registry = RemoteSessionRegistry()
        let supervisor = BoxdMachineSupervisor(
            boxd: boxd,
            registry: registry,
            settingsProvider: { BoxdSettings() },
            cliBundlePath: cliBundle,
            appVersion: "e2e-\(UUID().uuidString.prefix(6))",
            localHome: home,
            localKanbanHome: "\(home)/.kanban-code"
        )
        let collected = Collected()
        await supervisor.setDispatch { collected.add($0) }
        await supervisor.setProxyRunner { invocation in
            collected.add(invocation)
            return ShellCommand.Result(exitCode: 0, stdout: "proxied-ok card=\(invocation.cardId ?? "-") argv=\(invocation.request.argv.joined(separator: " "))\n", stderr: "")
        }

        let sessionName = "kanban-code-\(Self.cardId)"
        let machineName = BoxdLaunchPlanner.machineName(repoName: "kanban-code", cardId: Self.cardId)

        do {
            // 1. Create, bootstrap, init, copy.
            let preparation = try await supervisor.prepare(
                cardId: Self.cardId,
                localProjectPath: project,
                existingMachine: nil,
                worktreeName: nil,
                existingWorktree: nil,
                sessionNames: [sessionName],
                log: { line in collected.log(line) }
            )
            #expect(preparation.machineName == machineName)
            #expect(preparation.remoteProjectPath == "/home/boxd/kanban-code")
            #expect(preparation.remoteCwd == "/home/boxd/kanban-code")
            #expect(await supervisor.isConnected(machineName))
            #expect(registry.machine(forSession: sessionName) == machineName)

            let bridge = try #require(await supervisor.bridge(for: machineName))
            let env = try await bridge.exec(["cat", "/home/boxd/kanban-code/.env"])
            #expect(env.stdout.contains("E2E_SECRET=copied-from-mac"))
            let checkout = try await bridge.exec(["git", "-C", "/home/boxd/kanban-code", "rev-parse", "--is-inside-work-tree"])
            #expect(checkout.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
            let hooks = try await bridge.exec(["cat", "/home/boxd/.claude/settings.json"])
            #expect(hooks.stdout.contains("hook.sh"))

            // 2. Launch Claude on the machine through the routing adapter.
            let tmux = RoutingTmuxAdapter(local: TmuxAdapter(), registry: registry)
            let launcher = LaunchSession(tmux: tmux)
            let created = try await launcher.launch(
                sessionName: sessionName,
                projectPath: preparation.remoteCwd,
                prompt: "",
                worktreeName: nil,
                shellOverride: nil,
                extraEnv: preparation.extraEnv,
                skipPermissions: true,
                assistant: .claude
            )
            #expect(created == sessionName)
            await supervisor.exportSessionEnvironment(machineName: machineName, sessionName: sessionName, env: preparation.extraEnv)
            let live = try await tmux.listSessions()
            #expect(live.contains { $0.name == sessionName })

            try await ImageSender(tmux: tmux).waitForReady(sessionName: sessionName, assistant: .claude)
            try await tmux.sendPrompt(to: sessionName, text: "Reply with exactly the word PONG and nothing else.")

            // 3. The transcript and the hook events reach the temporary home with local paths.
            let projectDir = "\(home)/.claude/projects/\(SessionFileMover.encodeProjectPath(project))"
            var mirrored: String?
            for _ in 0..<120 {
                if let files = try? FileManager.default.contentsOfDirectory(atPath: projectDir),
                   let file = files.first(where: { $0.hasSuffix(".jsonl") }) {
                    let content = (try? String(contentsOfFile: "\(projectDir)/\(file)", encoding: .utf8)) ?? ""
                    if content.contains("\"cwd\":\"\(project)\"") || content.contains("\"cwd\":\"\(project.replacingOccurrences(of: "/", with: "\\/"))\"") {
                        mirrored = content
                        break
                    }
                }
                try await Task.sleep(for: .seconds(1))
            }
            let transcript = try #require(mirrored, "no mirrored transcript with the local cwd under \(projectDir)")
            #expect(!transcript.contains("/home/boxd/kanban-code"))
            #expect(transcript.contains("PONG"))

            var hookLines = ""
            for _ in 0..<30 {
                hookLines = (try? String(contentsOfFile: "\(home)/.kanban-code/hook-events.jsonl", encoding: .utf8)) ?? ""
                if hookLines.contains("\"sessionId\"") { break }
                try await Task.sleep(for: .seconds(1))
            }
            #expect(hookLines.contains("\"transcriptPath\":\"\(projectDir)") || hookLines.contains(projectDir.replacingOccurrences(of: "/", with: "\\/")))
            #expect(!hookLines.contains("/home/boxd/.claude"))
            #expect(await supervisor.lastActivity(of: machineName) != nil)

            // 4. A kanban command inside the machine is answered by the Mac.
            let proxied = try await bridge.exec(
                ["bash", "-lc", "KANBAN_REMOTE_PROXY=1 KANBAN_CARD_ID=\(Self.cardId) KANBAN_CODE_HOME=/home/boxd/.kanban-code ~/.local/bin/kanban list"],
                stdin: nil, cwd: "/home/boxd/kanban-code", timeout: 60)
            #expect(proxied.stdout.contains("proxied-ok card=\(Self.cardId)"), "stdout: \(proxied.stdout) stderr: \(proxied.stderr)")
            #expect(collected.proxyRequests.first?.request.argv.contains("list") == true)

            // 5. Stop parks the machine on disk; resume brings it back cold.
            await supervisor.stop(machineName: machineName, reason: .sessionStopped)
            let stoppedMachine = try await boxd.getMachine(name: machineName)
            #expect(stoppedMachine.status == .stopped, "status after stop: \(stoppedMachine.status)")
            #expect(!(await supervisor.isConnected(machineName)))
            #expect(registry.state(of: machineName) == .paused(.sessionStopped))
            let keptNames = try await tmux.listSessions().map(\.name)
            #expect(keptNames.contains(sessionName), "stopped machine keeps its known sessions in the list")
            await #expect(throws: RemoteMachineUnavailable.self) {
                try await tmux.capturePane(sessionName: sessionName)
            }

            let again = try await supervisor.prepare(
                cardId: Self.cardId,
                localProjectPath: project,
                existingMachine: machineName,
                worktreeName: nil,
                existingWorktree: nil,
                sessionNames: [sessionName],
                runInit: false,
                log: { line in collected.log(line) }
            )
            #expect(again.machineName == machineName)
            // The stop was cold: the machine is back, the session is not,
            // and the launch flow would start it again from the transcript.
            #expect(!(await supervisor.hasSession(machineName: machineName, sessionName: sessionName)))

            let states = collected.states.map(\.1)
            #expect(states.contains(.connected))
            #expect(states.contains(.paused(.sessionStopped)))
        } catch {
            print("[e2e] FAILED: \(error)\n[e2e] log:\n" + collected.logText)
            if let bridge = await supervisor.bridge(for: machineName) {
                let pane = try? await bridge.exec(["tmux", "capture-pane", "-p", "-t", sessionName])
                print("[e2e] pane:\n" + (pane?.stdout ?? "<none>") + "\n[e2e] pane stderr: " + (pane?.stderr ?? ""))
                let remoteFiles = try? await bridge.exec(["bash", "-c", "find /home/boxd/.claude/projects /home/boxd/.kanban-code -name '*.jsonl' -newer /home/boxd/.kanban-code/cli/VERSION -exec ls -la {} \\; 2>/dev/null; tail -c 600 /home/boxd/.kanban-code/hook-events.jsonl 2>/dev/null"])
                print("[e2e] remote transcripts and hook events:\n" + (remoteFiles?.stdout ?? ""))
            }
            if let mirror = await supervisor.mirror(for: machineName) {
                print("[e2e] mirror offsets: \(await mirror.offsets.filter { !$0.key.contains("/langwatch") })")
            }
            let localTree = (try? await ShellCommand.run("/usr/bin/find", arguments: [home, "-type", "f"]))?.stdout ?? ""
            print("[e2e] local home files:\n" + localTree)
            try? await supervisor.destroy(machineName: machineName)
            throw error
        }

        // 6. Destroy.
        try await supervisor.destroy(machineName: machineName)
        let gone = try? await boxd.getMachine(name: machineName)
        #expect(gone == nil || gone?.status == .destroyed)
    }
}
