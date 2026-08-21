import Foundation
import Testing

@testable import KanbanCodeCore

/// One GitHub refresh pass used to look up every PR the board has ever seen:
/// hundreds of merged PRs on archived cards across a hundred repos, minutes of
/// gh calls, all inside the reconcile that everything else waits behind. The
/// scope keeps the pass to what can still change.
@Suite("PRRefreshScope")
struct PRRefreshScopeTests {

    private func link(
        column: KanbanCodeColumn,
        projectPath: String? = "/repo",
        branch: String? = nil,
        prs: [PRLink] = []
    ) -> Link {
        var link = Link(projectPath: projectPath, column: column)
        if let branch {
            link.worktreeLink = WorktreeLink(path: "/repo/wt", branch: branch)
        }
        link.prLinks = prs
        return link
    }

    @Test("active card's worktree branch is collected")
    func activeBranchCollected() {
        let scope = PRRefreshScope.collect(links: [
            link(column: .inProgress, branch: "feat/x")
        ])
        #expect(scope.branchesByRepo == ["/repo": ["feat/x"]])
    }

    @Test("discovered branches route through discoveredRepos")
    func discoveredBranchesRouted() {
        var l = link(column: .waiting)
        l.discoveredBranches = ["feat/a", "feat/b"]
        l.discoveredRepos = ["feat/b": "/other-repo"]
        let scope = PRRefreshScope.collect(links: [l])
        #expect(scope.branchesByRepo == ["/repo": ["feat/a"], "/other-repo": ["feat/b"]])
    }

    @Test("archived card gets no branch discovery")
    func archivedNoBranchDiscovery() {
        var l = link(
            column: .allSessions, branch: "feat/old",
            prs: [PRLink(number: 1, status: .approved)])
        l.discoveredBranches = ["feat/old2"]
        let scope = PRRefreshScope.collect(links: [l])
        #expect(scope.branchesByRepo.isEmpty)
    }

    @Test("merged PRs are never refreshed")
    func mergedNeverRefreshed() {
        let scope = PRRefreshScope.collect(links: [
            link(column: .done, prs: [PRLink(number: 1, status: .merged)]),
            link(column: .allSessions, prs: [PRLink(number: 2, status: .merged)]),
        ])
        #expect(scope.prNumbersByRepo.isEmpty)
    }

    @Test("open PR on an archived card still refreshes")
    func archivedOpenPRRefreshes() {
        let scope = PRRefreshScope.collect(links: [
            link(column: .allSessions, prs: [PRLink(number: 7, status: .reviewNeeded)])
        ])
        #expect(scope.prNumbersByRepo == ["/repo": [7]])
    }

    @Test("closed PR refreshes on the board, not off it")
    func closedPRScopedByColumn() {
        let scope = PRRefreshScope.collect(links: [
            link(column: .inReview, prs: [PRLink(number: 3, status: .closed)]),
            link(column: .allSessions, prs: [PRLink(number: 4, status: .closed)]),
        ])
        #expect(scope.prNumbersByRepo == ["/repo": [3]])
    }

    @Test("a PR with unknown status refreshes")
    func unknownStatusRefreshes() {
        let scope = PRRefreshScope.collect(links: [
            link(column: .allSessions, prs: [PRLink(number: 9)])
        ])
        #expect(scope.prNumbersByRepo == ["/repo": [9]])
    }

    @Test("backlog cards refresh PR status but discover no branches")
    func backlogPRsOnly() {
        let scope = PRRefreshScope.collect(links: [
            link(column: .backlog, branch: "feat/y", prs: [PRLink(number: 5, status: .pendingCI)])
        ])
        #expect(scope.branchesByRepo.isEmpty)
        #expect(scope.prNumbersByRepo == ["/repo": [5]])
    }

    @Test("a card without a project path contributes nothing")
    func noProjectPath() {
        let scope = PRRefreshScope.collect(links: [
            link(column: .inProgress, projectPath: nil, branch: "feat/z",
                 prs: [PRLink(number: 6, status: .reviewNeeded)])
        ])
        #expect(scope == PRRefreshScope.Scope())
    }
}
