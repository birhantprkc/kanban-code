import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("CardReconciler: remote cards")
struct BoxdCardReconcilerTests {

    private func remoteLink(
        id: String = "card_remote",
        machine: String = "m",
        sessionName: String = "repo-remote",
        worktreePath: String? = nil
    ) -> Link {
        Link(
            id: id,
            name: "Remote card",
            projectPath: "/work/repo",
            column: .inProgress,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: sessionName),
            worktreeLink: worktreePath.map { WorktreeLink(path: $0, branch: "feature") },
            isRemote: true,
            remote: RemoteLink(machineName: machine, remoteProjectPath: "/home/boxd/repo", remoteHome: "/home/boxd")
        )
    }

    private func localLink(
        id: String = "card_local",
        sessionName: String = "repo-local",
        worktreePath: String? = nil
    ) -> Link {
        Link(
            id: id,
            name: "Local card",
            projectPath: "/work/repo",
            column: .inProgress,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: sessionName),
            worktreeLink: worktreePath.map { WorktreeLink(path: $0, branch: "feature") }
        )
    }

    // MARK: - tmux

    @Test("An empty tmux scan of no machine leaves a remote card's session alone")
    func remoteKeepsTmuxWhenItsMachineIsNotInTheScan() throws {
        let snapshot = CardReconciler.DiscoverySnapshot(
            tmuxSessions: [],
            didScanTmux: true,
            connectedRemoteMachines: []
        )

        let result = CardReconciler.reconcile(existing: [remoteLink(), localLink()], snapshot: snapshot)

        let remote = try #require(result.first { $0.id == "card_remote" })
        let local = try #require(result.first { $0.id == "card_local" })
        #expect(remote.tmuxLink?.sessionName == "repo-remote")
        #expect(local.tmuxLink == nil)
    }

    @Test("An empty tmux scan of the card's machine clears its session")
    func remoteLosesTmuxWhenItsMachineWasScanned() throws {
        let snapshot = CardReconciler.DiscoverySnapshot(
            tmuxSessions: [],
            didScanTmux: true,
            connectedRemoteMachines: ["m"]
        )

        let result = CardReconciler.reconcile(existing: [remoteLink()], snapshot: snapshot)

        #expect(try #require(result.first).tmuxLink == nil)
    }

    @Test("A live session on the scanned machine is kept")
    func remoteKeepsALiveSession() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            tmuxSessions: [TmuxSession(name: "repo-remote", path: "/home/boxd/repo")],
            didScanTmux: true,
            connectedRemoteMachines: ["m"]
        )

        let result = CardReconciler.reconcile(existing: [remoteLink()], snapshot: snapshot)

        #expect(result.first(where: { $0.id == "card_remote" })?.tmuxLink?.sessionName == "repo-remote")
    }

    // MARK: - worktrees

    @Test("A missing local worktree path clears a local link but not a remote one")
    func remoteKeepsItsWorktreeLink() throws {
        let snapshot = CardReconciler.DiscoverySnapshot(
            didScanTmux: false,
            worktrees: ["/work/repo": [Worktree(path: "/work/repo", branch: "main")]]
        )
        let existing = [
            remoteLink(worktreePath: "/home/boxd/repo/.claude/worktrees/feature"),
            localLink(worktreePath: "/work/repo/.claude/worktrees/feature"),
        ]

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)

        let remote = try #require(result.first { $0.id == "card_remote" })
        let local = try #require(result.first { $0.id == "card_local" })
        #expect(remote.worktreeLink?.path == "/home/boxd/repo/.claude/worktrees/feature")
        #expect(local.worktreeLink == nil)
    }

    @Test("A worktree that is in the scan is kept for a local card")
    func localKeepsALiveWorktree() {
        let path = "/work/repo/.claude/worktrees/feature"
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: ["/work/repo": [Worktree(path: path, branch: "feature")]]
        )

        let result = CardReconciler.reconcile(existing: [localLink(worktreePath: path)], snapshot: snapshot)

        #expect(result.first?.worktreeLink?.path == path)
    }
}
