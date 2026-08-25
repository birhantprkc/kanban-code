import Foundation
import Testing

@testable import KanbanCodeCore

/// Work in one project often ships a change to a sibling repository too, and
/// the card carries both pull requests. The refresh asked the card's own
/// repository for every number on it, so the sibling's pull request was
/// looked up under a repository it does not live in. That number either
/// belongs to an unrelated pull request there or does not exist, and the
/// card kept the status it had when the link was made, for good.
@Suite("Cross-repo PR refresh")
struct CrossRepoPRRefreshTests {

    private let project = "/Users/dev/langwatch"

    private func card(prs: [PRLink]) -> Link {
        var link = Link(projectPath: project, column: .inReview)
        link.prLinks = prs
        return link
    }

    // MARK: - Reading the repository off the pull request

    @Test("a pull request URL names its own repository")
    func repoKeyFromURL() {
        let pr = PRLink(number: 925, url: "https://github.com/langwatch/scenario/pull/925")
        #expect(pr.repoKey == "github.com/langwatch/scenario")
    }

    @Test("a self-hosted host keeps its own key")
    func repoKeyKeepsHost() {
        let pr = PRLink(number: 7, url: "https://github.acme.com/acme/tools/pull/7")
        #expect(pr.repoKey == "github.acme.com/acme/tools")
    }

    @Test("a pull request with no usable URL has no repository of its own")
    func repoKeyMissing() {
        #expect(PRLink(number: 1).repoKey == nil)
        #expect(PRLink(number: 1, url: "not a url at all").repoKey == nil)
        #expect(PRLink(number: 1, url: "https://github.com/langwatch").repoKey == nil)
        // An issue URL is not a pull request URL.
        #expect(PRLink(number: 1, url: "https://github.com/o/r/issues/1").repoKey == nil)
    }

    // MARK: - Scope

    @Test("a sibling repository's pull request is scoped to that repository")
    func siblingPRRoutedByURL() {
        let scope = PRRefreshScope.collect(links: [
            card(prs: [
                PRLink(
                    number: 925, url: "https://github.com/langwatch/scenario/pull/925",
                    status: .approved),
                PRLink(
                    number: 7266, url: "https://github.com/langwatch/langwatch/pull/7266",
                    status: .reviewNeeded),
            ])
        ])

        #expect(scope.prNumbersByRepoKey["github.com/langwatch/scenario"] == [925])
        #expect(scope.prNumbersByRepoKey["github.com/langwatch/langwatch"] == [7266])
        // Nothing falls through to the card's project any more.
        #expect(scope.prNumbersByRepo.isEmpty)
        // The card's checkout is what `gh` runs from for the sibling.
        #expect(scope.lookupDirForRepoKey["github.com/langwatch/scenario"] == project)
    }

    @Test("a pull request with no URL still uses the card's project")
    func urllessPRFallsBackToProject() {
        let scope = PRRefreshScope.collect(links: [card(prs: [PRLink(number: 42)])])

        #expect(scope.prNumbersByRepo == [project: [42]])
        #expect(scope.prNumbersByRepoKey.isEmpty)
    }

    @Test("a merged sibling pull request is still never refreshed")
    func mergedSiblingStaysOut() {
        let scope = PRRefreshScope.collect(links: [
            card(prs: [
                PRLink(
                    number: 925, url: "https://github.com/langwatch/scenario/pull/925",
                    status: .merged)
            ])
        ])

        #expect(scope.prNumbersByRepoKey.isEmpty)
    }

    // MARK: - Grouping

    private func slugByPrefix(_ root: String) -> (owner: String, name: String, host: String)? {
        root.contains("langwatch") ? ("langwatch", "langwatch", "github.com") : nil
    }

    @Test("a sibling repository gets its own query, run from the card's checkout")
    func siblingGetsOwnGroup() async {
        let groups = await PRLookupGrouping.group(
            branchesByRepo: [:],
            prNumbersByRepo: [:],
            prNumbersByRepoKey: ["github.com/langwatch/scenario": [925]],
            lookupDirForRepoKey: ["github.com/langwatch/scenario": project],
            slugForRoot: slugByPrefix
        )

        let key = "github.com/langwatch/scenario"
        #expect(groups.numbers[key] == [925])
        #expect(groups.representativeRoot[key] == project)
        // The checkout is another repository's, so the query has to name this one.
        #expect(groups.explicitRepo[key]?.owner == "langwatch")
        #expect(groups.explicitRepo[key]?.name == "scenario")
    }

    @Test("a pull request in the card's own repository costs no second query")
    func sameRepoFoldsIntoTheRootGroup() async {
        let groups = await PRLookupGrouping.group(
            branchesByRepo: [project: ["feat/x"]],
            prNumbersByRepo: [:],
            prNumbersByRepoKey: ["github.com/langwatch/langwatch": [7266]],
            lookupDirForRepoKey: ["github.com/langwatch/langwatch": project],
            slugForRoot: slugByPrefix
        )

        let key = "github.com/langwatch/langwatch"
        #expect(groups.representativeRoot.count == 1)
        #expect(groups.numbers[key] == [7266])
        #expect(groups.branches[key] == ["feat/x"])
        // It resolved from a real checkout, so it needs no repository override.
        #expect(groups.explicitRepo[key] == nil)
    }

    @Test("a repository with no checkout to run from is dropped, not misrouted")
    func noLookupDirIsDropped() async {
        let groups = await PRLookupGrouping.group(
            branchesByRepo: [:],
            prNumbersByRepo: [:],
            prNumbersByRepoKey: ["github.com/langwatch/scenario": [925]],
            lookupDirForRepoKey: [:],
            slugForRoot: slugByPrefix
        )

        #expect(groups.representativeRoot.isEmpty)
        #expect(groups.numbers.isEmpty)
    }
}
