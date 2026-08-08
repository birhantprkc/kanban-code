import AppKit
import MarkdownUI
import SwiftUI
import Testing

@testable import KanbanCode

/// A message has to report a height that covers everything it draws. An
/// NSTextView does not clip, so a short answer here does not truncate: it draws
/// the overflow straight over the next message.
@MainActor
@Suite("Chat text height")
struct ChatTextHeightTests {

    static let width: CGFloat = 690

    static let appearance = ChatTextAppearance(
        font: .systemFont(ofSize: 13), foregroundColor: .labelColor
    )

    /// Everything the layout actually covers, tables included.
    static func drawnBottom(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(
            size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        let full = NSRange(location: 0, length: layout.numberOfGlyphs)
        var bottom = layout.boundingRect(forGlyphRange: full, in: container).maxY
        layout.enumerateLineFragments(forGlyphRange: full) { rect, used, _, _, _ in
            bottom = max(bottom, max(rect.maxY, used.maxY))
        }
        return bottom
    }

    static func table(rows: Int) -> String {
        let header = "| Item | $/mo |\n| --- | --- |"
        let body = (1...rows).map { "| Row \($0) with a longer label | ~$\($0)00 |" }
        return ([header] + body).joined(separator: "\n")
    }

    @Test("a message ending in a table reports the table's full height")
    func trailingTableIsCovered() {
        let markdown = """
            Same pattern elsewhere: Loki bursts to 3.21 cores and 7.87 GiB, and
            keeper memory is under-requested.

            **Where that leaves the ladder**

            \(Self.table(rows: 8))
            """
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(content: .markdown(markdown), appearance: Self.appearance, highlight: nil)
        let reported = view.fittingSize(forWidth: Self.width).height

        let attributed = ChatAttributedText.make(
            content: .markdown(markdown), appearance: Self.appearance, width: Self.width)
        let drawn = Self.drawnBottom(attributed, width: Self.width)

        print("trailing table: reported=\(reported) drawn=\(drawn)")
        #expect(reported >= drawn)
    }

    /// Expanding "Show more" swaps a truncated body for the full one. The view
    /// is reused, so a height cached against the old text would leave the rest
    /// of the message drawing over its neighbours.
    @Test("expanding a truncated message reports the taller height")
    func expandingRemeasures() {
        let full = """
            Intro paragraph that stays put.

            \(Self.table(rows: 12))
            """
        let truncated = String(full.prefix(120))

        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(content: .markdown(truncated), appearance: Self.appearance, highlight: nil)
        let short = view.fittingSize(forWidth: Self.width)
        view.setFrameSize(NSSize(width: Self.width, height: short.height))

        view.configure(content: .markdown(full), appearance: Self.appearance, highlight: nil)
        let expanded = view.fittingSize(forWidth: Self.width).height

        let attributed = ChatAttributedText.make(
            content: .markdown(full), appearance: Self.appearance, width: Self.width)
        let drawn = Self.drawnBottom(attributed, width: Self.width)

        print("expanded: short=\(short.height) expanded=\(expanded) drawn=\(drawn)")
        #expect(expanded > short.height)
        #expect(expanded >= drawn)
    }

    /// The size a view reports is the size it gets. If it asks for less width
    /// than it was offered, it has to still fit in the height it asked for at
    /// that narrower width, or the text re-wraps taller and draws over the
    /// message below.
    static func fitsInTheSizeItAsksFor(_ content: ChatTextContent) -> Bool {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(content: content, appearance: Self.appearance, highlight: nil)
        let asked = view.fittingSize(forWidth: Self.width)
        view.setFrameSize(asked)

        guard let layout = view.layoutManager, let container = view.textContainer else {
            return false
        }
        layout.ensureLayout(for: container)
        var bottom = layout.usedRect(for: container).maxY
        let full = NSRange(location: 0, length: layout.numberOfGlyphs)
        layout.enumerateLineFragments(forGlyphRange: full) { rect, used, _, _, _ in
            bottom = max(bottom, max(rect.maxY, used.maxY))
        }
        print("asked=\(asked) drawnAtThatWidth=\(bottom)")
        return bottom <= asked.height + 0.5
    }

    @Test("a message with a table fits the size it asks for")
    func tableFitsItsOwnSize() {
        #expect(
            Self.fitsInTheSizeItAsksFor(
                .markdown(
                    """
                    **Where that leaves the ladder**

                    \(Self.table(rows: 10))
                    """)))
    }

    @Test("a code block fits the size it asks for")
    func codeBlockFitsItsOwnSize() {
        #expect(Self.fitsInTheSizeItAsksFor(.markdown("Intro.\n\n```\nlet a = 1\n```")))
    }

    @Test("a paragraph fits the size it asks for")
    func proseFitsItsOwnSize() {
        let long = String(repeating: "wrapping prose that keeps on going ", count: 8)
        #expect(Self.fitsInTheSizeItAsksFor(.markdown(long)))
        #expect(Self.fitsInTheSizeItAsksFor(.plain(long)))
        #expect(Self.fitsInTheSizeItAsksFor(.inlineMarkdown(long)))
    }

    /// SwiftUI asks for the minimum, ideal and maximum size with zero,
    /// unspecified and infinite widths. Those have to answer with the width the
    /// row is laid out at: nil sends SwiftUI to the text view's own fitting
    /// size, which follows whatever was last rendered, and a stale narrow
    /// answer becomes a narrow frame.
    @Test("probes for minimum, ideal and maximum answer with the layout width")
    func probesAnswerWithTheLayoutWidth() {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(
            content: .markdown("| A | B |\n| --- | --- |\n| 1 | 2 |"),
            appearance: Self.appearance, highlight: nil)
        _ = view.fittingSize(for: ProposedViewSize(width: Self.width, height: nil))

        for probe in [
            ProposedViewSize.zero, ProposedViewSize.unspecified, ProposedViewSize.infinity,
        ] {
            #expect(view.fittingSize(for: probe)?.width == Self.width)
        }
    }

    /// A message that starts as running text and grows a table mid-stream keeps
    /// being laid out at the width it was measured at, not the narrower one the
    /// running text asked for.
    @Test("a table arriving mid stream lays out at the full width")
    func tableArrivingMidStream() {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(content: .inlineMarkdown("Short."), appearance: Self.appearance, highlight: nil)
        let narrow = view.fittingSize(for: ProposedViewSize(width: Self.width, height: nil))
        #expect((narrow?.width ?? Self.width) < 100)
        view.setFrameSize(narrow ?? .zero)

        view.configure(
            content: .markdown("Short.\n\n\(Self.table(rows: 3))"),
            appearance: Self.appearance, highlight: nil)
        let wide = view.fittingSize(for: ProposedViewSize(width: Self.width, height: nil))
        #expect(wide?.width == Self.width)

        view.setFrameSize(wide ?? .zero)
        guard let layout = view.layoutManager, let container = view.textContainer else {
            Issue.record("no layout")
            return
        }
        #expect(container.size.width == Self.width)
        layout.ensureLayout(for: container)
        var bottom = layout.usedRect(for: container).maxY
        layout.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)
        ) { rect, used, _, _, _ in
            bottom = max(bottom, max(rect.maxY, used.maxY))
        }
        #expect(bottom <= (wide?.height ?? 0) + 0.5)
    }

    @Test("a table wider than the container still reports what it draws")
    func wideTableIsCovered() {
        let markdown = """
            | Dev load balancers (PR coming) | Topology hints (applied, ratchets in) | Notes |
            | --- | --- | --- |
            | ~$226 | ~$100-150 | a longer note that has to wrap inside its own column |
            | ~$100 | ~$639 withdrawn | another note that also wraps a fair amount here |
            """
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(content: .markdown(markdown), appearance: Self.appearance, highlight: nil)
        let reported = view.fittingSize(forWidth: Self.width).height

        let attributed = ChatAttributedText.make(
            content: .markdown(markdown), appearance: Self.appearance, width: Self.width)
        let drawn = Self.drawnBottom(attributed, width: Self.width)

        print("wide table: reported=\(reported) drawn=\(drawn)")
        #expect(reported >= drawn)
    }
}
