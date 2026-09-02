import Foundation
import Testing
import KanbanCodeCore

@testable import KanbanCode

/// The tabs a card offers in the "..." menu and in the inspector.
@Suite("Detail tabs")
struct DetailTabTests {
    @Test("A plain session has the terminal and the history")
    func plainSession() {
        let card = KanbanCodeCard(link: Link(id: "c1"))

        #expect(DetailTab.available(for: card) == [.terminal, .history])
    }

    @Test("A prompt adds its tab, an issue takes its place")
    func promptAndIssue() {
        var link = Link(id: "c1")
        link.promptBody = "fix the build"
        #expect(DetailTab.available(for: KanbanCodeCard(link: link)) == [.terminal, .history, .prompt])

        link.issueLink = IssueLink(number: 7, url: "https://github.com/acme/repo/issues/7", title: "Build is red")
        #expect(DetailTab.available(for: KanbanCodeCard(link: link)) == [.terminal, .history, .issue])
    }

    @Test("Pull requests add their tab")
    func pullRequests() {
        var link = Link(id: "c1")
        link.prLinks = [PRLink(number: 12, url: "https://github.com/acme/repo/pull/12")]

        #expect(DetailTab.available(for: KanbanCodeCard(link: link)) == [.terminal, .history, .pullRequest])
        #expect(DetailTab.pullRequest.title == "Pull Request")
    }
}
