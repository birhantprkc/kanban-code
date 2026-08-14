import AppKit
import Testing

@testable import KanbanCode

@MainActor
@Suite("Chat link colour")
struct ChatLinkColorTests {

    private static let textColor = NSColor.labelColor
    private static let appearance = ChatTextAppearance(
        font: .systemFont(ofSize: 13), foregroundColor: textColor
    )

    /// The colour and destination of the run holding `label`.
    private static func link(
        _ label: String, in content: ChatTextContent
    ) -> (color: NSColor?, url: URL?) {
        let attributed = ChatAttributedText.make(
            content: content, appearance: appearance, width: 400)
        let range = (attributed.string as NSString).range(of: label)
        guard range.location != NSNotFound else {
            Issue.record("label not in the rendered text: \(label)")
            return (nil, nil)
        }
        let attributes = attributed.attributes(at: range.location, effectiveRange: nil)
        return (attributes[.foregroundColor] as? NSColor, attributes[.link] as? URL)
    }

    private static func rgb(_ color: NSColor?) -> [CGFloat]? {
        guard let converted = color?.usingColorSpace(.sRGB) else { return nil }
        return [converted.redComponent, converted.greenComponent, converted.blueComponent]
    }

    @Test("a link in a message without block markdown is drawn as a link")
    func inlineLinkIsColoured() {
        let hit = Self.link(
            "the ADR",
            in: .inlineMarkdown("It is at [the ADR](https://example.com/adr) for you to read.")
        )

        #expect(hit.url == URL(string: "https://example.com/adr"))
        #expect(Self.rgb(hit.color) != Self.rgb(Self.textColor))
        #expect(Self.rgb(hit.color) == Self.rgb(ChatAttributedText.linkColor))
    }

    @Test("both markdown paths draw a link in the same colour")
    func bothPathsAgree() {
        let text = "It is at [the ADR](https://example.com/adr) for you to read."

        let inline = Self.link("the ADR", in: .inlineMarkdown(text))
        let block = Self.link("the ADR", in: .markdown(text))

        #expect(Self.rgb(block.color) != nil)
        #expect(Self.rgb(inline.color) == Self.rgb(block.color))
    }

    @Test("text around a link keeps the colour of the message")
    func surroundingTextIsUntouched() {
        let hit = Self.link(
            "It is at",
            in: .inlineMarkdown("It is at [the ADR](https://example.com/adr) for you to read.")
        )

        #expect(hit.url == nil)
        #expect(Self.rgb(hit.color) == Self.rgb(Self.textColor))
    }

    @Test("a bare URL is a link too")
    func bareURL() {
        let hit = Self.link(
            "https://example.com/adr", in: .inlineMarkdown("Read https://example.com/adr today."))

        #expect(hit.url == URL(string: "https://example.com/adr"))
        #expect(Self.rgb(hit.color) == Self.rgb(ChatAttributedText.linkColor))
    }
}
