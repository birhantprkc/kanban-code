import AppKit
import Testing

@testable import KanbanCode

@MainActor
@Suite("Selectable markdown text")
struct SelectableMarkdownTextTests {

    static let tableMarkdown = """
        | Component | Version | Notes |
        | --- | --- | --- |
        | alpha | 1.2.0 | first |
        | beta | 3.4.5 | second |
        """

    static let appearance = ChatTextAppearance(
        font: .systemFont(ofSize: 13), foregroundColor: .labelColor
    )

    private static func columnOrigins(_ view: SelectableMarkdownText.WrappingTextView) -> [CGFloat] {
        guard let layout = view.layoutManager, let container = view.textContainer else { return [] }
        layout.ensureLayout(for: container)
        var origins: Set<CGFloat> = []
        var index = 0
        while index < layout.numberOfGlyphs {
            var effective = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            origins.insert(rect.minX)
            index = NSMaxRange(effective)
        }
        return origins.sorted()
    }

    /// The view is configured before SwiftUI has given it a frame, so its first
    /// `configure` runs at width zero. Table columns are sized against the
    /// available width, so rendering at that point collapses every column to a
    /// single character and draws the message over its neighbours.
    @Test("renders at the proposed width even before it has a frame")
    func rendersAtProposedWidthWithoutAFrame() {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(
            content: .markdown(Self.tableMarkdown), appearance: Self.appearance, highlight: nil)
        #expect(view.bounds.width == 0)

        let size = view.fittingSize(forWidth: 690)
        #expect(size.width > 200)
        #expect(size.height > 40)

        let origins = Self.columnOrigins(view)
        #expect(origins.count == 3)
        if origins.count == 3 {
            // Columns spread across the width rather than stacking at the left.
            #expect(origins[1] - origins[0] > 40)
            #expect(origins[2] - origins[1] > 40)
        }
    }

    /// System notices sit inside a centring `HStack`. A row that reports the
    /// full proposed width leaves the spacers nothing to take, so it drifts to
    /// the leading edge instead of staying centred.
    @Test("reports its own width so short rows can be centred")
    func shortRowReportsItsOwnWidth() {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(
            content: .plain("Background command completed"),
            appearance: Self.appearance,
            highlight: nil
        )
        let size = view.fittingSize(forWidth: 690)
        #expect(size.width < 400)
    }

    @Test("takes the full width when the text needs it")
    func wrappingRowTakesTheFullWidth() {
        let long = String(repeating: "wrapping text that keeps going ", count: 12)
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(content: .plain(long), appearance: Self.appearance, highlight: nil)
        let size = view.fittingSize(forWidth: 690)
        #expect(size.width > 600)
        #expect(size.height > 20)
    }

    /// A table narrower than the container keeps its content width, so the
    /// table that proves a re-render has to be wide enough to be squeezed.
    @Test("re-renders when the width changes")
    func reRendersOnWidthChange() {
        let wideTable = """
            | Component | Notes |
            | --- | --- |
            | a fairly long component name here | an even longer note that will \
            not fit in a narrow container without being squeezed |
            """
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(content: .markdown(wideTable), appearance: Self.appearance, highlight: nil)
        _ = view.fittingSize(forWidth: 400)
        let narrow = Self.columnOrigins(view)

        view.setFrameSize(NSSize(width: 900, height: 400))
        let wide = Self.columnOrigins(view)

        #expect(narrow.count == 2)
        #expect(wide.count == 2)
        if narrow.count == 2, wide.count == 2 {
            #expect(wide[1] > narrow[1])
        }
    }
}
