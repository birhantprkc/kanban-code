import AppKit
import SwiftUI
import Testing

@testable import KanbanCode

/// The diff rows as a stack of coloured `Text` views, which is what they were
/// before they moved into one selectable run. Kept here so the replacement can
/// be measured against it rather than eyeballed.
private struct LegacyDiffRows: View {
    let oldText: String
    let newText: String

    private var diffLines: [(text: String, isAdded: Bool, isRemoved: Bool)] {
        var result: [(String, Bool, Bool)] = []
        for line in oldText.components(separatedBy: "\n") { result.append((line, false, true)) }
        for line in newText.components(separatedBy: "\n") { result.append((line, true, false)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diffLines.indices, id: \.self) { i in
                let line = diffLines[i]
                Text((line.isRemoved ? "- " : "+ ") + line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(
                        line.isRemoved
                            ? Color(red: 1, green: 0.4, blue: 0.4)
                            : Color(red: 0.4, green: 0.9, blue: 0.4)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .background(
                        line.isRemoved ? Color.red.opacity(0.12) : Color.green.opacity(0.1))
            }
        }
        .background(Color(white: 0.1))
    }
}

private struct CurrentDiffRows: View {
    let oldText: String
    let newText: String

    var body: some View {
        SelectableMarkdownText(
            content: .diff(old: oldText, new: newText),
            appearance: .init(
                font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                foregroundColor: .labelColor
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.1))
    }
}

@MainActor
@Suite("Chat card text parity")
struct ChatCardTextParityTests {

    static let width: CGFloat = 620

    static let oldText = """
        let total = items.count
        return total
        """
    static let newText = """
        let total = items.filter { $0.isVisible }.count
        return max(total, 0)
        """

    @Test("the diff keeps the height it had as a stack of rows")
    func diffHeightMatches() throws {
        let legacy = try #require(
            MarkdownParityTests.swiftUIImage(
                LegacyDiffRows(oldText: Self.oldText, newText: Self.newText), width: Self.width))
        let current = try #require(
            MarkdownParityTests.swiftUIImage(
                CurrentDiffRows(oldText: Self.oldText, newText: Self.newText), width: Self.width))

        try MarkdownParityTests.writeComparison(
            legacy, current, to: ".claude/tmp/markdown-parity/diff-side-by-side.png")

        print("diff legacy=\(legacy.size.height) current=\(current.size.height)")
        #expect(abs(legacy.size.height - current.size.height) <= 1)

        // Height alone would pass with the text sitting anywhere inside its
        // band, so compare where the glyphs actually landed.
        let legacyRows = Self.textRows(legacy)
        let currentRows = Self.textRows(current)
        print("diff rows legacy=\(legacyRows) current=\(currentRows)")
        #expect(legacyRows.count == currentRows.count)
        for (a, b) in zip(legacyRows, currentRows) {
            #expect(abs(a.first - b.first) <= 1)
            #expect(abs(a.last - b.last) <= 1)
        }
    }

    /// The rows of pixels each line of text covers, top to bottom.
    private static func textRows(_ image: NSImage) -> [(first: Int, last: Int)] {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return [] }
        var runs: [(first: Int, last: Int)] = []
        var start = -1
        for y in 0..<rep.pixelsHigh {
            var lit = false
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                if colour.redComponent > 0.55 || colour.greenComponent > 0.55 {
                    lit = true
                    break
                }
            }
            if lit, start < 0 { start = y }
            if !lit, start >= 0 {
                runs.append((start, y - 1))
                start = -1
            }
        }
        if start >= 0 { runs.append((start, rep.pixelsHigh - 1)) }
        return runs
    }

    /// The bands behind the lines span the container, so the run has to claim
    /// the full width even though its longest line is shorter.
    @Test("the diff takes the full width so its bands do too")
    func diffFillsTheWidth() {
        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(
            content: .diff(old: "a", new: "b"),
            appearance: .init(
                font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                foregroundColor: .labelColor
            ),
            highlight: nil
        )
        #expect(view.fittingSize(forWidth: Self.width).width == Self.width)
    }

    @Test("a code block claims the full width, a paragraph does not")
    func codeBlockFillsTheWidth() {
        let appearance = ChatTextAppearance(
            font: .systemFont(ofSize: 13), foregroundColor: .labelColor)

        let code = SelectableMarkdownText.WrappingTextView.make()
        code.configure(content: .markdown("```\nlet a = 1\n```"), appearance: appearance, highlight: nil)
        #expect(code.fittingSize(forWidth: Self.width).width == Self.width)

        let prose = SelectableMarkdownText.WrappingTextView.make()
        prose.configure(content: .markdown("A short line."), appearance: appearance, highlight: nil)
        #expect(prose.fittingSize(forWidth: Self.width).width < 200)
    }

    /// Tool results were capped at 20 lines with `lineLimit`; the cap now lives
    /// on the text container so a wrapped line still ends in an ellipsis.
    @Test("a capped block stops at its line limit")
    func lineLimitCapsTheHeight() {
        let appearance = ChatTextAppearance(
            font: .monospacedSystemFont(ofSize: 10, weight: .regular),
            foregroundColor: .secondaryLabelColor
        )
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")

        let capped = SelectableMarkdownText.WrappingTextView.make()
        capped.configure(
            content: .plain(firstLines(long, limit: 20)), appearance: appearance,
            highlight: nil, lineLimit: 20)
        let uncapped = SelectableMarkdownText.WrappingTextView.make()
        uncapped.configure(content: .plain(long), appearance: appearance, highlight: nil)

        let cappedHeight = capped.fittingSize(forWidth: Self.width).height
        let uncappedHeight = uncapped.fittingSize(forWidth: Self.width).height
        #expect(cappedHeight < uncappedHeight)
        #expect(abs(cappedHeight - uncappedHeight / 2) <= 2)
    }

    /// A single wrapped line has to keep wrapping under a cap, not get cut at
    /// the first screenful.
    @Test("a capped block still truncates a wrapping line")
    func lineLimitTruncatesWrappedText() {
        let appearance = ChatTextAppearance(
            font: .monospacedSystemFont(ofSize: 10, weight: .regular),
            foregroundColor: .secondaryLabelColor
        )
        let paragraph = String(repeating: "wrapping output that keeps going ", count: 60)

        let view = SelectableMarkdownText.WrappingTextView.make()
        view.configure(
            content: .plain(paragraph), appearance: appearance, highlight: nil, lineLimit: 3)
        let capped = view.fittingSize(forWidth: Self.width).height

        let free = SelectableMarkdownText.WrappingTextView.make()
        free.configure(content: .plain(paragraph), appearance: appearance, highlight: nil)
        #expect(capped < free.fittingSize(forWidth: Self.width).height)
        #expect(capped < 60)
    }
}
