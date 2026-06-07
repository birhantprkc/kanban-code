import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Domain Entities")
struct EntityTests {
    @Test("Session displayTitle uses name first")
    func sessionDisplayTitle() {
        let session = Session(id: "abc-123", name: "My Session", firstPrompt: "Hello")
        #expect(session.displayTitle == "My Session")
    }

    @Test("Session displayTitle falls back to firstPrompt")
    func sessionDisplayTitleFallback() {
        let session = Session(id: "abc-123", firstPrompt: "Fix the login bug")
        #expect(session.displayTitle == "Fix the login bug")
    }

    @Test("Session displayTitle falls back to ID prefix")
    func sessionDisplayTitleIdFallback() {
        let session = Session(id: "abc-12345-678")
        #expect(session.displayTitle == "abc-1234...")
    }

    @Test("PullRequest status derivation — failing CI")
    func prStatusFailing() {
        let pr = PullRequest(
            number: 1, title: "Test", state: "open", url: "", headRefName: "feat",
            checksStatus: .fail
        )
        #expect(pr.status == .failing)
    }

    @Test("PullRequest status derivation — unresolved threads")
    func prStatusUnresolved() {
        let pr = PullRequest(
            number: 1, title: "Test", state: "open", url: "", headRefName: "feat",
            checksStatus: .pass, unresolvedThreads: 3
        )
        #expect(pr.status == .unresolved)
    }

    @Test("PullRequest status derivation — approved")
    func prStatusApproved() {
        let pr = PullRequest(
            number: 1, title: "Test", state: "open", url: "", headRefName: "feat",
            reviewDecision: "APPROVED", checksStatus: .pass
        )
        #expect(pr.status == .approved)
    }

    @Test("PullRequest status derivation — merged")
    func prStatusMerged() {
        let pr = PullRequest(
            number: 1, title: "Test", state: "merged", url: "", headRefName: "feat"
        )
        #expect(pr.status == .merged)
    }

    @Test("PRStatus ordering — failing has highest urgency")
    func prStatusOrdering() {
        #expect(PRStatus.failing < PRStatus.unresolved)
        #expect(PRStatus.unresolved < PRStatus.changesRequested)
        #expect(PRStatus.changesRequested < PRStatus.reviewNeeded)
        #expect(PRStatus.reviewNeeded < PRStatus.approved)
        #expect(PRStatus.approved < PRStatus.merged)
    }

    @Test("KanbanCodeColumn display names")
    func columnDisplayNames() {
        #expect(KanbanCodeColumn.inProgress.displayName == "In Progress")
        #expect(KanbanCodeColumn.waiting.displayName == "Waiting")
        #expect(KanbanCodeColumn.allSessions.displayName == "All Sessions")
    }

    @Test("KanbanCodeColumn allows board task creation only in working lanes")
    func columnBoardTaskCreationEligibility() {
        #expect(KanbanCodeColumn.backlog.allowsBoardTaskCreation)
        #expect(KanbanCodeColumn.inProgress.allowsBoardTaskCreation)
        #expect(KanbanCodeColumn.waiting.allowsBoardTaskCreation)
        #expect(KanbanCodeColumn.inReview.allowsBoardTaskCreation)
        #expect(KanbanCodeColumn.done.allowsBoardTaskCreation)
        #expect(!KanbanCodeColumn.allSessions.allowsBoardTaskCreation)
    }

    @Test("Worktree directoryName extracts last component")
    func worktreeDirectoryName() {
        let wt = Worktree(path: "/Users/rchaves/Projects/repo/.claude/worktrees/feat-login", branch: "feat/login")
        #expect(wt.directoryName == "feat-login")
    }

    @Test("Project effectiveRepoRoot uses repoRoot when set")
    func projectRepoRoot() {
        let p = Project(path: "/a/b/langwatch", repoRoot: "/a/b")
        #expect(p.effectiveRepoRoot == "/a/b")
    }

    @Test("Project effectiveRepoRoot falls back to path")
    func projectRepoRootFallback() {
        let p = Project(path: "/a/b/langwatch")
        #expect(p.effectiveRepoRoot == "/a/b/langwatch")
    }

    // MARK: - Codable round-trips

    @Test("CheckRun Codable round-trip")
    func checkRunCodable() throws {
        let run = CheckRun(name: "build", status: .completed, conclusion: .success)
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(CheckRun.self, from: data)
        #expect(decoded == run)
    }

    @Test("CheckRun with in_progress status Codable")
    func checkRunInProgressCodable() throws {
        let run = CheckRun(name: "deploy", status: .inProgress)
        let data = try JSONEncoder().encode(run)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("in_progress"))
        let decoded = try JSONDecoder().decode(CheckRun.self, from: data)
        #expect(decoded == run)
        #expect(decoded.conclusion == nil)
    }

    @Test("PRLink with new fields Codable round-trip")
    func prLinkCodable() throws {
        let link = PRLink(
            number: 42,
            url: "https://github.com/org/repo/pull/42",
            status: .approved,
            unresolvedThreads: 2,
            title: "Fix login flow",
            approvalCount: 3,
            checkRuns: [
                CheckRun(name: "build", status: .completed, conclusion: .success),
                CheckRun(name: "lint", status: .completed, conclusion: .failure),
            ]
        )
        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(PRLink.self, from: data)
        #expect(decoded == link)
        #expect(decoded.title == "Fix login flow")
        #expect(decoded.approvalCount == 3)
        #expect(decoded.checkRuns?.count == 2)
    }

    @Test("PRLink backward-compat decodes without new fields")
    func prLinkBackwardCompat() throws {
        let json = #"{"number":7,"url":"https://example.com/pull/7","status":"approved"}"#
        let decoded = try JSONDecoder().decode(PRLink.self, from: json.data(using: .utf8)!)
        #expect(decoded.number == 7)
        #expect(decoded.title == nil)
        #expect(decoded.approvalCount == nil)
        #expect(decoded.checkRuns == nil)
    }

    @Test("IssueLink with title Codable round-trip")
    func issueLinkCodable() throws {
        let link = IssueLink(number: 123, url: "https://github.com/org/repo/issues/123", body: "Fix bug", title: "Login broken")
        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(IssueLink.self, from: data)
        #expect(decoded == link)
        #expect(decoded.title == "Login broken")
    }

    @Test("IssueLink backward-compat decodes without title")
    func issueLinkBackwardCompat() throws {
        let json = #"{"number":5,"body":"some body"}"#
        let decoded = try JSONDecoder().decode(IssueLink.self, from: json.data(using: .utf8)!)
        #expect(decoded.number == 5)
        #expect(decoded.title == nil)
        #expect(decoded.body == "some body")
    }

    @Test("QueuedPrompt self-compact metadata round-trips")
    func queuedPromptSelfCompactMetadataCodable() throws {
        let prompt = QueuedPrompt(
            id: "prompt_compact",
            body: "compact soon",
            sendAutomatically: true,
            selfCompactThresholdTokens: 600_000
        )
        let data = try JSONEncoder().encode(prompt)
        let decoded = try JSONDecoder().decode(QueuedPrompt.self, from: data)
        #expect(decoded == prompt)
        #expect(decoded.selfCompactThresholdTokens == 600_000)
    }

    @Test("QueuedPrompt backward-compat decodes without self-compact metadata")
    func queuedPromptBackwardCompatNoSelfCompactMetadata() throws {
        let json = #"{"id":"prompt_old","body":"hello","sendAutomatically":true}"#
        let decoded = try JSONDecoder().decode(QueuedPrompt.self, from: json.data(using: .utf8)!)
        #expect(decoded.id == "prompt_old")
        #expect(decoded.body == "hello")
        #expect(decoded.sendAutomatically)
        #expect(decoded.selfCompactThresholdTokens == nil)
    }

    // MARK: - TmuxLink

    @Test("TmuxLink defaults to Claude session (not shell-only)")
    func tmuxLinkDefaultNotShellOnly() {
        let tmux = TmuxLink(sessionName: "my-project")
        #expect(tmux.isShellOnly == nil)
        #expect(tmux.sessionName == "my-project")
    }

    @Test("TmuxLink shell-only flag round-trips through JSON")
    func tmuxLinkShellOnlyRoundTrip() throws {
        let tmux = TmuxLink(sessionName: "my-project", isShellOnly: true)
        #expect(tmux.isShellOnly == true)

        let data = try JSONEncoder().encode(tmux)
        let decoded = try JSONDecoder().decode(TmuxLink.self, from: data)
        #expect(decoded.isShellOnly == true)
        #expect(decoded.sessionName == "my-project")
    }

    @Test("TmuxLink backward-compat decodes without isShellOnly")
    func tmuxLinkBackwardCompat() throws {
        let json = #"{"sessionName":"old-session"}"#
        let decoded = try JSONDecoder().decode(TmuxLink.self, from: json.data(using: .utf8)!)
        #expect(decoded.sessionName == "old-session")
        #expect(decoded.isShellOnly == nil)
    }
}
