import Foundation

/// Groups per-worktree PR lookups by repository identity so N worktrees of
/// one repository cost one batched gh query instead of N, and routes group
/// results back to every member root.
public enum PRLookupGrouping {

    public struct Groups {
        /// group key → the root the gh call runs from
        public var representativeRoot: [String: String] = [:]
        /// group key → every root folded into the group
        public var members: [String: [String]] = [:]
        /// group key → union of branch lookups across members
        public var branches: [String: Set<String>] = [:]
        /// group key → union of PR-number lookups across members
        public var numbers: [String: Set<Int>] = [:]

        public init() {}
    }

    /// Group lookup requests by repository slug. Roots that fail to resolve
    /// keep a group of their own, keyed by the root path, so an unknown
    /// remote degrades to the old per-root behavior instead of breaking.
    /// Roots with nothing to look up are dropped. Iteration is sorted so the
    /// representative root is deterministic.
    public static func group(
        branchesByRepo: [String: Set<String>],
        prNumbersByRepo: [String: Set<Int>],
        slugForRoot: @Sendable (String) async -> (owner: String, name: String, host: String)?
    ) async -> Groups {
        var groups = Groups()
        let allRepos = Set(branchesByRepo.keys).union(prNumbersByRepo.keys)
        for repoRoot in allRepos.sorted() {
            let branches = branchesByRepo[repoRoot] ?? []
            let numbers = prNumbersByRepo[repoRoot] ?? []
            guard !branches.isEmpty || !numbers.isEmpty else { continue }
            let slug = await slugForRoot(repoRoot)
            let key = slug.map { "\($0.host)/\($0.owner)/\($0.name)" } ?? repoRoot
            if groups.representativeRoot[key] == nil { groups.representativeRoot[key] = repoRoot }
            groups.members[key, default: []].append(repoRoot)
            groups.branches[key, default: []].formUnion(branches)
            groups.numbers[key, default: []].formUnion(numbers)
        }
        return groups
    }

    /// Route one group's by-number results to every member root that asked
    /// for numbers, and only those, since downstream consumers look PRs up
    /// by the card's own repoRoot.
    public static func distribute(
        byNumber: [Int: PullRequest],
        toMembers members: [String],
        requestedNumbers prNumbersByRepo: [String: Set<Int>],
        into prsByRepoAndNumber: inout [String: [Int: PullRequest]]
    ) {
        guard !byNumber.isEmpty else { return }
        for member in members where !(prNumbersByRepo[member] ?? []).isEmpty {
            prsByRepoAndNumber[member] = byNumber
        }
    }
}
