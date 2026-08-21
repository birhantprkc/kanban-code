import Foundation

/// Decides which branches and PR numbers a GitHub refresh pass looks up.
///
/// The board carries hundreds of finished cards whose pull requests can never
/// change again, and looking them all up made one refresh pass take minutes
/// across a hundred repos. The scope keeps the pass to what can still move:
/// branch discovery for cards on the board, and status refresh for pull
/// requests not in a final state.
public enum PRRefreshScope {
    public struct Scope: Equatable, Sendable {
        public var branchesByRepo: [String: Set<String>]
        public var prNumbersByRepo: [String: Set<Int>]

        public init(
            branchesByRepo: [String: Set<String>] = [:],
            prNumbersByRepo: [String: Set<Int>] = [:]
        ) {
            self.branchesByRepo = branchesByRepo
            self.prNumbersByRepo = prNumbersByRepo
        }
    }

    /// Columns whose cards still get branch → PR discovery. Backlog cards have
    /// no PRs yet and archived cards get no new ones.
    private static let activeColumns: Set<KanbanCodeColumn> = [
        .inProgress, .waiting, .inReview, .done,
    ]

    public static func collect(links: [Link]) -> Scope {
        var scope = Scope()
        for link in links {
            guard let repoRoot = link.projectPath, !repoRoot.isEmpty else { continue }
            let isActive = activeColumns.contains(link.column)

            if isActive {
                if let branch = link.worktreeLink?.branch {
                    scope.branchesByRepo[repoRoot, default: []].insert(branch)
                }
                if let discovered = link.discoveredBranches {
                    for branch in discovered {
                        // discoveredRepos routes branches pushed to another repo
                        let effectiveRepo = link.discoveredRepos?[branch] ?? repoRoot
                        scope.branchesByRepo[effectiveRepo, default: []].insert(branch)
                    }
                }
            }

            for pr in link.prLinks {
                // Merged is final. Closed can in principle reopen, but not on
                // a card already off the board.
                if pr.status == .merged { continue }
                if !isActive && pr.status == .closed { continue }
                scope.prNumbersByRepo[repoRoot, default: []].insert(pr.number)
            }
        }
        return scope
    }
}
