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
        /// group key → the repository to name in the query, for groups whose
        /// representative root is a checkout of a different repository. A
        /// card's pull request in a sibling repository has no checkout of
        /// its own to run from, so it borrows one and names its repository.
        public var explicitRepo: [String: (owner: String, name: String)] = [:]

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
        prNumbersByRepoKey: [String: Set<Int>] = [:],
        lookupDirForRepoKey: [String: String] = [:],
        slugForRoot: @Sendable (String) async -> (owner: String, name: String, host: String)?
    ) async -> Groups {
        var groups = Groups()
        // host → a checkout of it. `gh` reads the API host from the
        // directory it runs in, so a borrowed checkout must be on the same
        // host as the repository the query names.
        var rootOnHost: [String: String] = [:]
        let allRepos = Set(branchesByRepo.keys).union(prNumbersByRepo.keys)
        for repoRoot in allRepos.sorted() {
            let branches = branchesByRepo[repoRoot] ?? []
            let numbers = prNumbersByRepo[repoRoot] ?? []
            guard !branches.isEmpty || !numbers.isEmpty else { continue }
            let slug = await slugForRoot(repoRoot)
            let key = slug.map { "\($0.host)/\($0.owner)/\($0.name)" } ?? repoRoot
            if let slug, rootOnHost[slug.host] == nil { rootOnHost[slug.host] = repoRoot }
            if groups.representativeRoot[key] == nil { groups.representativeRoot[key] = repoRoot }
            groups.members[key, default: []].append(repoRoot)
            groups.branches[key, default: []].formUnion(branches)
            groups.numbers[key, default: []].formUnion(numbers)
        }

        // Pull requests routed by their own URL. A key already present is a
        // repository some root resolved to, so its numbers join that query
        // rather than paying for a second one.
        for key in prNumbersByRepoKey.keys.sorted() {
            let numbers = prNumbersByRepoKey[key] ?? []
            guard !numbers.isEmpty else { continue }
            if groups.representativeRoot[key] == nil {
                guard let repo = repoFromKey(key) else { continue }
                let host = key.split(separator: "/").first.map(String.init)
                guard let dir = host.flatMap({ rootOnHost[$0] }) ?? lookupDirForRepoKey[key] else {
                    continue
                }
                groups.representativeRoot[key] = dir
                groups.explicitRepo[key] = repo
            }
            groups.numbers[key, default: []].formUnion(numbers)
        }
        return groups
    }

    /// Split a "host/owner/name" key back into the repository it names.
    private static func repoFromKey(_ key: String) -> (owner: String, name: String)? {
        let parts = key.split(separator: "/").map(String.init)
        guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
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
