import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("PRLookupGrouping")
struct PRLookupGroupingTests {

    private func slugByPrefix(_ root: String) -> (owner: String, name: String, host: String)? {
        if root.contains("fork") { return ("someoneelse", "langwatch", "github.com") }
        if root.contains("langwatch-saas") { return ("langwatch", "langwatch-saas", "github.com") }
        if root.contains("langwatch") { return ("langwatch", "langwatch", "github.com") }
        return nil
    }

    private func pr(_ number: Int) -> PullRequest {
        PullRequest(number: number, title: "t\(number)", state: "open", url: "u", headRefName: "b\(number)")
    }

    @Test("worktrees of one repository fold into one group with unioned lookups")
    func worktreesFold() async {
        let groups = await PRLookupGrouping.group(
            branchesByRepo: [
                "/p/langwatch": ["main-fix"],
                "/p/langwatch/.claude/worktrees/a": ["feat-a"],
                "/p/langwatch/.claude/worktrees/b": ["feat-b"],
            ],
            prNumbersByRepo: [
                "/p/langwatch/.claude/worktrees/a": [101],
                "/p/langwatch/.claude/worktrees/b": [202],
            ],
            slugForRoot: slugByPrefix
        )
        #expect(groups.representativeRoot.count == 1)
        let key = "github.com/langwatch/langwatch"
        #expect(groups.branches[key] == ["main-fix", "feat-a", "feat-b"])
        #expect(groups.numbers[key] == [101, 202])
        #expect(Set(groups.members[key] ?? []) == [
            "/p/langwatch", "/p/langwatch/.claude/worktrees/a", "/p/langwatch/.claude/worktrees/b",
        ])
    }

    @Test("different repositories and forks stay separate")
    func forksStaySeparate() async {
        let groups = await PRLookupGrouping.group(
            branchesByRepo: [
                "/p/langwatch": ["x"],
                "/p/langwatch-saas": ["y"],
                "/p/fork-of-langwatch": ["z"],
            ],
            prNumbersByRepo: [:],
            slugForRoot: slugByPrefix
        )
        #expect(groups.representativeRoot.count == 3)
        #expect(groups.branches["github.com/langwatch/langwatch"] == ["x"])
        #expect(groups.branches["github.com/langwatch/langwatch-saas"] == ["y"])
        #expect(groups.branches["github.com/someoneelse/langwatch"] == ["z"])
    }

    @Test("an unresolvable root keys its own group by path")
    func unresolvableRoot() async {
        let groups = await PRLookupGrouping.group(
            branchesByRepo: ["/p/no-remote": ["b"]],
            prNumbersByRepo: [:],
            slugForRoot: { _ in nil }
        )
        #expect(groups.representativeRoot["/p/no-remote"] == "/p/no-remote")
        #expect(groups.members["/p/no-remote"] == ["/p/no-remote"])
    }

    @Test("roots with nothing to look up are dropped")
    func emptyRootsDropped() async {
        let groups = await PRLookupGrouping.group(
            branchesByRepo: ["/p/langwatch": []],
            prNumbersByRepo: ["/p/langwatch": []],
            slugForRoot: slugByPrefix
        )
        #expect(groups.representativeRoot.isEmpty)
    }

    @Test("representative root is deterministic: sorted-first member")
    func deterministicRepresentative() async {
        for _ in 0..<5 {
            let groups = await PRLookupGrouping.group(
                branchesByRepo: [
                    "/p/langwatch/.claude/worktrees/zebra": ["z"],
                    "/p/langwatch/.claude/worktrees/alpha": ["a"],
                ],
                prNumbersByRepo: [:],
                slugForRoot: slugByPrefix
            )
            #expect(groups.representativeRoot["github.com/langwatch/langwatch"]
                    == "/p/langwatch/.claude/worktrees/alpha")
        }
    }

    @Test("results distribute to every member that requested numbers, and only those")
    func distributeToRequesters() async {
        let requested: [String: Set<Int>] = [
            "/p/wt-a": [101],
            "/p/wt-b": [202],
        ]
        var out: [String: [Int: PullRequest]] = [:]
        PRLookupGrouping.distribute(
            byNumber: [101: pr(101), 202: pr(202)],
            toMembers: ["/p/wt-a", "/p/wt-b", "/p/wt-branches-only"],
            requestedNumbers: requested,
            into: &out
        )
        #expect(out["/p/wt-a"]?[101]?.number == 101)
        #expect(out["/p/wt-b"]?[202]?.number == 202)
        #expect(out["/p/wt-branches-only"] == nil)
    }

    @Test("empty results distribute nothing")
    func emptyResults() async {
        var out: [String: [Int: PullRequest]] = [:]
        PRLookupGrouping.distribute(
            byNumber: [:],
            toMembers: ["/p/wt-a"],
            requestedNumbers: ["/p/wt-a": [1]],
            into: &out
        )
        #expect(out.isEmpty)
    }
}
