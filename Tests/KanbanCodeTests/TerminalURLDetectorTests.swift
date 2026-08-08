import Foundation
import Testing

@testable import KanbanCode

@Suite("Terminal URL detector")
struct TerminalURLDetectorTests {
    private func detect(_ text: String, clickOn fragment: String, base: String? = nil) -> TerminalURLDetector.Detection? {
        guard let range = text.range(of: fragment) else {
            Issue.record("fragment not in text: \(fragment)")
            return nil
        }
        let col = text.distance(from: text.startIndex, to: range.lowerBound)
        return TerminalURLDetector.detect(in: text, col: col, githubBaseURL: base)
    }

    @Test("Trailing comma is not part of the URL")
    func trailingComma() {
        let text = "The plan is live: https://nexus.langwatch.ai/wiki/langy-launch-content, with the umbrella story"
        let hit = detect(text, clickOn: "nexus.langwatch.ai")
        #expect(hit?.url == "https://nexus.langwatch.ai/wiki/langy-launch-content")
    }

    @Test("Trailing period is not part of the URL")
    func trailingPeriod() {
        let text = "The PR is up: https://github.com/langwatch/langwatch-saas/pull/769. I'll watch it"
        let hit = detect(text, clickOn: "github.com")
        #expect(hit?.url == "https://github.com/langwatch/langwatch-saas/pull/769")
    }

    @Test("Multiple trailing punctuation characters are stripped")
    func trailingEllipsis() {
        let text = "loading https://example.com/page..."
        let hit = detect(text, clickOn: "example.com")
        #expect(hit?.url == "https://example.com/page")
    }

    @Test("Clicking the trailing comma itself is not a link hit")
    func clickOnComma() {
        let text = "see https://example.com/page, more"
        let hit = detect(text, clickOn: ", more")
        #expect(hit == nil)
    }

    @Test("Interior dots and URL characters survive")
    func interiorPreserved() {
        let text = "docs at https://example.com/a.b/c?x=1&y=2#frag end"
        let hit = detect(text, clickOn: "example.com")
        #expect(hit?.url == "https://example.com/a.b/c?x=1&y=2#frag")
    }

    @Test("Highlight range matches the trimmed URL")
    func highlightRangeTrimmed() {
        let text = "x https://example.com/foo, y"
        guard let hit = detect(text, clickOn: "example.com") else { return }
        let ns = text as NSString
        let highlighted = ns.substring(with: NSRange(location: hit.colStart, length: hit.colEnd - hit.colStart + 1))
        #expect(highlighted == "https://example.com/foo")
    }

    @Test("Bare #123 resolves against the card's GitHub base")
    func bareIssueRef() {
        let text = "fixed in #123 today"
        let hit = detect(text, clickOn: "#123", base: "https://github.com/langwatch/langwatch")
        #expect(hit?.url == "https://github.com/langwatch/langwatch/pull/123")
    }

    @Test("owner/repo#123 resolves without a base")
    func qualifiedIssueRef() {
        let text = "see langwatch/kanban-code#65 for details"
        let hit = detect(text, clickOn: "#65")
        #expect(hit?.url == "https://github.com/langwatch/kanban-code/pull/65")
    }

    /// A sibling repo is usually written on its own, and used to be dead text.
    @Test("repo#123 takes the owner from the card's repo")
    func repoOnlyIssueRef() {
        let text = "Fix is up: kanban-code#6745."
        let hit = detect(text, clickOn: "kanban-code#6745", base: "https://github.com/langwatch/langwatch")
        #expect(hit?.url == "https://github.com/langwatch/kanban-code/pull/6745")
        // The whole reference highlights, not just the number.
        #expect(hit?.colStart == 11)
        #expect(hit?.colEnd == 26)
    }

    @Test("clicking the repo name of repo#123 is a hit too")
    func repoOnlyIssueRefClickedOnName() {
        let text = "shipped scenario#41 today"
        let hit = detect(text, clickOn: "scenario", base: "https://github.com/langwatch/langwatch")
        #expect(hit?.url == "https://github.com/langwatch/scenario/pull/41")
    }

    @Test("repo#123 stays plain text when there is no repo to infer from")
    func repoOnlyIssueRefWithoutBase() {
        let text = "shipped scenario#41 today"
        #expect(detect(text, clickOn: "scenario") == nil)
    }

    /// The lookbehind is what keeps a fragment in a URL from reading as one.
    @Test("a URL fragment is not a reference")
    func urlFragmentIsNotARef() {
        let text = "docs at https://example.com/a#5 end"
        let hit = detect(text, clickOn: "example.com", base: "https://github.com/langwatch/langwatch")
        #expect(hit?.url == "https://example.com/a#5")
    }

    @Test("the owner comes off a repo URL with or without a scheme")
    func ownerParsing() {
        #expect(TerminalURLDetector.owner(of: "https://github.com/langwatch/langwatch") == "langwatch")
        #expect(TerminalURLDetector.owner(of: "github.com/acme/widgets") == "acme")
        #expect(TerminalURLDetector.owner(of: nil) == nil)
        #expect(TerminalURLDetector.owner(of: "langwatch") == nil)
    }
}
