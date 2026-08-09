import AppKit
import Testing

@testable import KanbanCode

@MainActor
@Suite("Chat search highlight")
struct ChatSearchHighlightTests {

    private static let appearance = ChatTextAppearance(
        font: .systemFont(ofSize: 13), foregroundColor: .labelColor
    )

    private static func painted(_ text: String, query: String, isCurrent: Bool = false) -> [NSRange]
    {
        let attributed = ChatAttributedText.make(
            content: .plain(text),
            appearance: appearance,
            highlight: ChatTextHighlight(query: query, isCurrentMatch: isCurrent),
            width: 400
        )
        var ranges: [NSRange] = []
        attributed.enumerateAttribute(
            .backgroundColor, in: NSRange(location: 0, length: attributed.length), options: []
        ) { value, range, _ in
            if value is NSColor { ranges.append(range) }
        }
        return ranges
    }

    private static func substring(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    @Test("a match is painted")
    func paintsAMatch() {
        let text = "State on langwatch#6730 is green"

        let ranges = Self.painted(text, query: "#6730")

        #expect(ranges.count == 1)
        #expect(ranges.map { Self.substring(text, $0) } == ["#6730"])
    }

    @Test("every match is painted, not just the first")
    func paintsEveryMatch() {
        let text = "alpha and alpha and alpha"

        let ranges = Self.painted(text, query: "alpha")

        #expect(ranges.count == 3)
    }

    @Test("case does not have to match")
    func matchesCaseInsensitively() {
        let text = "Watcher STOOD down"

        let ranges = Self.painted(text, query: "stood")

        #expect(ranges.map { Self.substring(text, $0) } == ["STOOD"])
    }

    /// Chat rows carry emoji in status lines, and a character offset is one
    /// short of the UTF-16 offset an attribute is addressed by for every one of
    /// them. Anything after the first emoji used to be painted over the wrong
    /// words, or dropped for running off the end.
    @Test("a match after an emoji lands on the match")
    func survivesWideCharacters() {
        let text = "⏳ 🔍 ✅ the needle is here"

        let ranges = Self.painted(text, query: "needle")

        #expect(ranges.map { Self.substring(text, $0) } == ["needle"])
    }

    @Test("the match being visited is painted a different colour")
    func currentMatchIsDistinct() {
        let text = "the needle"
        let makeColor: (Bool) -> NSColor? = { current in
            ChatAttributedText.make(
                content: .plain(text),
                appearance: Self.appearance,
                highlight: ChatTextHighlight(query: "needle", isCurrentMatch: current),
                width: 400
            ).attribute(.backgroundColor, at: 4, effectiveRange: nil) as? NSColor
        }

        #expect(makeColor(true) != makeColor(false))
    }

    @Test("no query paints nothing")
    func emptyQueryPaintsNothing() {
        #expect(Self.painted("the needle", query: "").isEmpty)
    }
}
