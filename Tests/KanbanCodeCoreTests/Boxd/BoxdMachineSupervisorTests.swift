import Testing
import Foundation
@testable import KanbanCodeCore

/// Collects the actions the supervisor dispatches.
final class ActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _actions: [Action] = []

    func append(_ action: Action) {
        lock.lock(); defer { lock.unlock() }
        _actions.append(action)
    }

    var actions: [Action] {
        lock.lock(); defer { lock.unlock() }
        return _actions
    }

    var machineStates: [(machine: String, state: RemoteMachineState)] {
        actions.compactMap {
            guard case .remoteMachineStateChanged(let machine, let state) = $0 else { return nil }
            return (machine, state)
        }
    }
}

@Suite("BoxdMachineSupervisor")
struct BoxdMachineSupervisorTests {

    private func makeSupervisor(
        boxd: FakeBoxdPort,
        registry: RemoteSessionRegistry = RemoteSessionRegistry()
    ) -> BoxdMachineSupervisor {
        let home = NSTemporaryDirectory() + "boxd-supervisor-\(UUID().uuidString)"
        return BoxdMachineSupervisor(
            boxd: boxd,
            registry: registry,
            settingsProvider: { BoxdSettings() },
            cliBundlePath: nil,
            appVersion: "1.0.0-test",
            localHome: home,
            localKanbanHome: home + "/.kanban-code",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    // MARK: - Pure helpers

    @Test("repositoryRoot walks up out of a Claude worktree")
    func repositoryRootWalksUp() {
        #expect(BoxdMachineSupervisor.repositoryRoot(of: "/work/repo/.claude/worktrees/feature") == "/work/repo")
        #expect(BoxdMachineSupervisor.repositoryRoot(of: "/work/repo/.claude/worktrees/a/b") == "/work/repo")
        #expect(BoxdMachineSupervisor.repositoryRoot(of: "/work/repo") == "/work/repo")
        #expect(BoxdMachineSupervisor.repositoryRoot(of: "/work/repo/src") == "/work/repo/src")
    }

    @Test("sessionEnvironment carries the proxy flag, the card id and the remote kanban home")
    func sessionEnvironmentIsComplete() {
        let env = BoxdMachineSupervisor.sessionEnvironment(cardId: "card_1", remoteHome: "/home/boxd")

        #expect(env == [
            "KANBAN_REMOTE_PROXY": "1",
            "KANBAN_CARD_ID": "card_1",
            "KANBAN_CODE_HOME": "/home/boxd/.kanban-code",
            "LANG": "C.UTF-8",
        ])
    }

    @Test("attachCommand quotes every value it puts on the command line")
    func attachCommandQuotes() {
        let command = BoxdMachineSupervisor.attachCommand(
            boxdPath: "/usr/local/bin/boxd",
            machineName: "kanban-repo-1",
            sessionName: "repo-card_1"
        )

        #expect(command == "'/usr/local/bin/boxd' machine exec --tty 'kanban-repo-1' -- tmux attach -t 'repo-card_1'")
    }

    @Test("attachCommand survives a single quote in a name")
    func attachCommandEscapesQuotes() {
        let command = BoxdMachineSupervisor.attachCommand(
            boxdPath: "/opt/it's/boxd",
            machineName: "m",
            sessionName: "s"
        )

        #expect(command.contains(#"'/opt/it'\''s/boxd'"#))
    }

    @Test("createLocalWorktree refuses an empty name instead of using the worktrees folder itself")
    func createLocalWorktreeRefusesEmptyName() async throws {
        let root = NSTemporaryDirectory() + "kanban-worktree-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/.claude/worktrees", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        await #expect(throws: WorktreeError.self) {
            try await BoxdMachineSupervisor.createLocalWorktree(repoRoot: root, name: "")
        }
        await #expect(throws: WorktreeError.self) {
            try await BoxdMachineSupervisor.createLocalWorktree(repoRoot: root, name: "a/b")
        }
    }

    @Test("createLocalWorktree makes a new branch in the Claude worktree layout")
    func createLocalWorktreeMakesBranch() async throws {
        let root = NSTemporaryDirectory() + "kanban-worktree-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let git = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
        _ = try await ShellCommand.run(git, arguments: ["init", "-q", "-b", "main"], currentDirectory: root)
        _ = try await ShellCommand.run(git, arguments: ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], currentDirectory: root)

        let worktree = try await BoxdMachineSupervisor.createLocalWorktree(repoRoot: root, name: "calm-otter-ab12")

        #expect(worktree.path == root + "/.claude/worktrees/calm-otter-ab12")
        #expect(worktree.branch == "calm-otter-ab12")
        let branch = try await ShellCommand.run(git, arguments: ["rev-parse", "--abbrev-ref", "HEAD"], currentDirectory: worktree.path)
        #expect(branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "calm-otter-ab12")
    }

    @Test("remoteWorktreeScript covers the local branch, the remote branch and the new branch")
    func remoteWorktreeScriptCoversEveryBranch() {
        let script = BoxdMachineSupervisor.remoteWorktreeScript(
            repo: "/home/boxd/repo",
            worktreePath: "/home/boxd/repo/.claude/worktrees/feature",
            branch: "feature"
        )

        #expect(script.contains("cd '/home/boxd/repo'"))
        #expect(script.contains("git fetch origin 'feature' || true"))
        // Branch already on the machine.
        #expect(script.contains("git worktree add '/home/boxd/repo/.claude/worktrees/feature' 'feature'"))
        // Branch only on origin.
        #expect(script.contains("git worktree add --track -b 'feature' '/home/boxd/repo/.claude/worktrees/feature' origin/'feature'"))
        // Branch nowhere yet.
        #expect(script.contains("git worktree add -b 'feature' '/home/boxd/repo/.claude/worktrees/feature'"))
        // An existing worktree is only brought up to date.
        #expect(script.contains("git pull --ff-only || true"))
    }

    @Test("shellEscape wraps in single quotes and escapes the quotes inside")
    func shellEscapeQuotes() {
        #expect(BoxdMachineSupervisor.shellEscape("plain") == "'plain'")
        #expect(BoxdMachineSupervisor.shellEscape("it's") == #"'it'\''s'"#)
        #expect(BoxdMachineSupervisor.shellEscape("a b; rm -rf /") == "'a b; rm -rf /'")
    }

    // MARK: - pause

    @Test("Pausing a machine the supervisor never opened still pauses it and reports the state")
    func pauseUnknownMachine() async {
        let boxd = FakeBoxdPort()
        let registry = RemoteSessionRegistry()
        let supervisor = makeSupervisor(boxd: boxd, registry: registry)
        let recorder = ActionRecorder()
        await supervisor.setDispatch { @MainActor action in recorder.append(action) }

        await supervisor.pause(machineName: "kanban-repo-1", reason: .manual)

        #expect(boxd.callNames("pause") == ["kanban-repo-1"])
        #expect(registry.state(of: "kanban-repo-1") == .paused(.manual))
        let reported = recorder.machineStates
        #expect(reported.count == 1)
        #expect(reported[0].machine == "kanban-repo-1")
        #expect(reported[0].state == .paused(.manual))
    }

    @Test("A pause that the boxd CLI refuses is still reported to the board")
    func pauseToleratesACliFailure() async {
        let boxd = FakeBoxdPort()
        boxd.fail("pause", with: .commandFailed(command: "boxd machine stop", exitCode: 1, message: "busy"))
        let registry = RemoteSessionRegistry()
        let supervisor = makeSupervisor(boxd: boxd, registry: registry)
        let recorder = ActionRecorder()
        await supervisor.setDispatch { @MainActor action in recorder.append(action) }

        await supervisor.pause(machineName: "kanban-repo-1", reason: .systemSleep)

        #expect(boxd.callNames("pause") == ["kanban-repo-1"])
        #expect(recorder.machineStates.map(\.state) == [.paused(.systemSleep)])
    }

    // MARK: - destroy

    @Test("Destroying a machine removes it from boxd and from the registry")
    func destroyRemovesTheMachine() async throws {
        let boxd = FakeBoxdPort()
        let registry = RemoteSessionRegistry()
        registry.assign(sessionName: "repo-card_1", to: "kanban-repo-1")
        registry.setMachine("kanban-repo-1", state: .connected)
        let supervisor = makeSupervisor(boxd: boxd, registry: registry)

        try await supervisor.destroy(machineName: "kanban-repo-1")

        #expect(boxd.callNames("remove") == ["kanban-repo-1"])
        #expect(registry.state(of: "kanban-repo-1") == nil)
        #expect(registry.machine(forSession: "repo-card_1") == nil)
    }

    @Test("Destroying a machine boxd no longer has is not an error")
    func destroyToleratesNotFound() async throws {
        let boxd = FakeBoxdPort()
        boxd.fail("remove", with: .commandFailed(command: "boxd machine rm", exitCode: 1, message: "Machine Not Found"))
        let supervisor = makeSupervisor(boxd: boxd)

        try await supervisor.destroy(machineName: "kanban-repo-1")

        #expect(boxd.callNames("remove") == ["kanban-repo-1"])
    }

    @Test("Any other destroy failure is passed on")
    func destroyRethrowsOtherFailures() async {
        let boxd = FakeBoxdPort()
        let failure = BoxdError.commandFailed(command: "boxd machine rm", exitCode: 1, message: "permission denied")
        boxd.fail("remove", with: failure)
        let supervisor = makeSupervisor(boxd: boxd)

        await #expect(throws: failure) {
            try await supervisor.destroy(machineName: "kanban-repo-1")
        }
    }

    // MARK: - Queries

    @Test("isConnected follows the registry")
    func isConnectedFollowsTheRegistry() async {
        let registry = RemoteSessionRegistry()
        let supervisor = makeSupervisor(boxd: FakeBoxdPort(), registry: registry)

        #expect(await supervisor.isConnected("kanban-repo-1") == false)
        registry.setMachine("kanban-repo-1", state: .connected)
        #expect(await supervisor.isConnected("kanban-repo-1") == true)
        registry.disconnectMachine("kanban-repo-1", state: .paused(.manual))
        #expect(await supervisor.isConnected("kanban-repo-1") == false)
    }

    @Test("A machine with no bridge has no mirror and no last activity")
    func unknownMachineHasNoRuntime() async {
        let supervisor = makeSupervisor(boxd: FakeBoxdPort())

        #expect(await supervisor.bridge(for: "kanban-repo-1") == nil)
        #expect(await supervisor.mirror(for: "kanban-repo-1") == nil)
        #expect(await supervisor.lastActivity(of: "kanban-repo-1") == nil)
    }


    // MARK: - Sweep

    private func link(id: String, machine: String?, session: String? = nil, archived: Bool = false) -> Link {
        var link = Link(
            id: id,
            name: id,
            projectPath: "/work/repo",
            column: archived ? .allSessions : .inProgress,
            source: .manual,
            tmuxLink: session.map { TmuxLink(sessionName: $0) },
            isRemote: machine != nil,
            remote: machine.map { RemoteLink(machineName: $0, remoteProjectPath: "/home/boxd/repo", remoteCwd: "/home/boxd/repo", remoteHome: "/home/boxd") }
        )
        link.manuallyArchived = archived
        return link
    }

    @Test("sweep destroys idle orphans, pauses running ones and leaves used machines alone")
    func sweepCleansOrphans() async {
        let boxd = FakeBoxdPort()
        boxd.setMachine(BoxdMachine(name: "kanban-repo-orphan", status: .standby))
        boxd.setMachine(BoxdMachine(name: "kanban-repo-orphan-run", status: .running))
        boxd.setMachine(BoxdMachine(name: "kanban-repo-archived", status: .hibernated))
        boxd.setMachine(BoxdMachine(name: "kanban-repo-idle", status: .running))
        boxd.setMachine(BoxdMachine(name: "kanban-repo-live", status: .running))
        boxd.setMachine(BoxdMachine(name: "kanban-repo-paused", status: .standby))
        boxd.setMachine(BoxdMachine(name: "good-wolf", status: .running))
        boxd.setMachine(BoxdMachine(name: "my-own-box", status: .standby))
        let supervisor = makeSupervisor(boxd: boxd)

        let report = await supervisor.sweep(links: [
            link(id: "card_archived", machine: "kanban-repo-archived", archived: true),
            link(id: "card_idle", machine: "kanban-repo-idle"),
            link(id: "card_live", machine: "kanban-repo-live", session: "repo-card_live"),
            link(id: "card_paused", machine: "kanban-repo-paused"),
            link(id: "card_local", machine: nil, session: "repo-card_local"),
        ])

        #expect(Set(report.destroyed) == ["kanban-repo-orphan", "kanban-repo-archived"])
        #expect(Set(report.paused) == ["kanban-repo-orphan-run", "kanban-repo-idle"])
        #expect(Set(boxd.callNames("remove")) == ["kanban-repo-orphan", "kanban-repo-archived"])
        #expect(Set(boxd.callNames("pause")) == ["kanban-repo-orphan-run", "kanban-repo-idle"])
    }

    @Test("sweep never touches the source machine even when it matches the pattern")
    func sweepSkipsSourceMachine() async {
        let boxd = FakeBoxdPort()
        boxd.setMachine(BoxdMachine(name: "kanban-base", status: .standby))
        let home = NSTemporaryDirectory() + "boxd-supervisor-\(UUID().uuidString)"
        let supervisor = BoxdMachineSupervisor(
            boxd: boxd,
            registry: RemoteSessionRegistry(),
            settingsProvider: { BoxdSettings(sourceMachine: "kanban-base") },
            cliBundlePath: nil,
            appVersion: "1.0.0-test",
            localHome: home,
            localKanbanHome: home + "/.kanban-code"
        )

        let report = await supervisor.sweep(links: [])

        #expect(report == BoxdMachineSupervisor.SweepReport())
        #expect(boxd.callNames("remove").isEmpty)
    }

    @Test("sweep without a links provider does nothing")
    func sweepNeedsLinks() async {
        let boxd = FakeBoxdPort()
        boxd.setMachine(BoxdMachine(name: "kanban-repo-orphan", status: .standby))
        let supervisor = makeSupervisor(boxd: boxd)

        let report = await supervisor.sweepIfPossible()

        #expect(report == BoxdMachineSupervisor.SweepReport())
        #expect(boxd.callNames("listMachines").isEmpty)
    }

    // MARK: - Session environment

    @Test("The Claude token joins the session environment only when it is set")
    func sessionEnvironmentToken() {
        let plain = BoxdMachineSupervisor.sessionEnvironment(cardId: "card_1", remoteHome: "/home/boxd")
        #expect(plain["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(plain["KANBAN_CARD_ID"] == "card_1")

        let blank = BoxdMachineSupervisor.sessionEnvironment(cardId: "card_1", remoteHome: "/home/boxd", claudeOAuthToken: "  ")
        #expect(blank["CLAUDE_CODE_OAUTH_TOKEN"] == nil)

        let withToken = BoxdMachineSupervisor.sessionEnvironment(cardId: "card_1", remoteHome: "/home/boxd", claudeOAuthToken: " sk-ant-oat01-x \n")
        #expect(withToken["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat01-x")
    }
}
