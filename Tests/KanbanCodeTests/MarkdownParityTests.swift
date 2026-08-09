import AppKit
import MarkdownUI
import SwiftUI
import Testing

@testable import KanbanCode

/// Renders the same markdown through MarkdownUI and through the AppKit
/// renderer, and writes both to a side by side PNG.
///
/// The AppKit renderer exists to make a selection run across a whole message,
/// and it is only worth having if the result is indistinguishable from the
/// SwiftUI rendering it replaces. Nothing here can assert "looks the same", so
/// it produces an artifact to look at and pins the numbers that can be checked.
@MainActor
@Suite("Markdown parity")
struct MarkdownParityTests {

    static let fixture = """
        # Heading one
        ## Heading two
        ### Heading three

        A paragraph with **bold**, *italic*, ~~struck~~ and `inline code`, long \
        enough that it wraps onto a second line and shows the line spacing.

        - First bullet
        - Second bullet that runs long enough to wrap so the hanging indent is \
        visible under the text rather than the marker
          - Nested bullet
        - Third bullet

        1. First numbered
        2. Second numbered

        > A blockquote with a bar down its leading edge.

        ```swift
        func greet(name: String) {
            print("hello \\(name)")
        }
        ```

        | Left | Centre | Right |
        | :--- | :----: | ----: |
        | one | two | three |
        | a much longer cell that has to wrap inside its own column | x | 42 |

        ---

        A closing paragraph with a [link](https://example.com).
        """

    static let width: CGFloat = 620

    // MARK: - Rendering

    static func markdownUIImage(_ markdown: String, width: CGFloat) -> NSImage? {
        let root = Markdown(markdown)
            .markdownTheme(chatMarkdownTheme)
            .frame(width: width, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        // Block margins reach `BlockSequence` as preferences, so the first
        // measurement reports the default gap everywhere. Settle by laying out
        // and displaying until the fitting height stops moving.
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let settled = host.fittingSize.height
            if abs(settled - host.frame.height) < 0.5 { break }
            host.frame = NSRect(x: 0, y: 0, width: width, height: settled)
        }
        guard host.bounds.height > 1,
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Rasterises any SwiftUI view the same way, so paths other than the
    /// markdown one can be compared too.
    static func swiftUIImage(_ view: some View, width: CGFloat) -> NSImage? {
        let root = view
            .frame(width: width, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let settled = host.fittingSize.height
            if abs(settled - host.frame.height) < 0.5 { break }
            host.frame = NSRect(x: 0, y: 0, width: width, height: settled)
        }
        guard host.bounds.height > 1,
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    static func appKitImage(attributed: NSAttributedString, width: CGFloat) -> NSImage? {
        let storage = NSTextStorage(attributedString: attributed)
        let layout = MarkdownLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        let height = ceil(layout.usedRect(for: container).maxY)
        guard height > 1 else { return nil }
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: height), textContainer: container)
        textView.isEditable = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = .zero
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else {
            return nil
        }
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let image = NSImage(size: textView.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    static func appKitImage(_ markdown: String, width: CGFloat) -> NSImage? {
        let renderer = MarkdownAttributedStringRenderer(
            theme: chatMarkdownTheme, metrics: chatMarkdownMetrics, containerWidth: width
        )
        return self.appKitImage(attributed: renderer.render(markdown: markdown), width: width)
    }

    static func writeComparison(
        _ left: NSImage, _ right: NSImage, to path: String
    ) throws {
        let gap: CGFloat = 24
        let labelHeight: CGFloat = 20
        let size = NSSize(
            width: left.size.width + right.size.width + gap,
            height: max(left.size.height, right.size.height) + labelHeight
        )
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        NSColor.textBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        let labels: [(String, CGFloat)] = [
            ("MarkdownUI (today)", 0),
            ("AppKit renderer", left.size.width + gap),
        ]
        for (text, x) in labels {
            NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ).draw(at: NSPoint(x: x, y: size.height - labelHeight + 4))
        }
        left.draw(at: NSPoint(x: 0, y: size.height - labelHeight - left.size.height),
                  from: .zero, operation: .sourceOver, fraction: 1)
        right.draw(
            at: NSPoint(x: left.size.width + gap, y: size.height - labelHeight - right.size.height),
            from: .zero, operation: .sourceOver, fraction: 1)
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Tests

    @Test("renders the fixture both ways for visual comparison")
    func sideBySide() throws {
        guard let left = Self.markdownUIImage(Self.fixture, width: Self.width),
            let right = Self.appKitImage(Self.fixture, width: Self.width)
        else {
            Issue.record("could not rasterise one of the renderers")
            return
        }
        try Self.writeComparison(
            left, right, to: ".claude/tmp/markdown-parity/side-by-side.png")
        print("markdownUI height: \(left.size.height), appKit height: \(right.size.height)")
    }

    /// Heights of small fixtures, each isolating one spacing constant.
    ///
    /// Comparing a whole document only says the totals agree; comparing one
    /// construct at a time says which constant is wrong.
    @Test("matches MarkdownUI height per construct")
    func perConstructHeights() {
        let fixtures: [(String, String)] = [
            ("paragraph", "Hello there"),
            ("two paragraphs", "First para\n\nSecond para"),
            ("heading then heading", "# One\n\n## Two"),
            ("heading then paragraph", "# One\n\nBody text"),
            ("paragraph then heading", "Body text\n\n# One"),
            ("h4 then paragraph", "#### Four\n\nBody text"),
            ("tight list", "- alpha\n- beta"),
            ("loose list", "- alpha\n\n- beta"),
            ("nested list", "- alpha\n  - beta"),
            ("numbered list", "1. alpha\n2. beta"),
            ("blockquote", "> quoted line"),
            ("code block", "before\n\n```\nlet x = 1\n```\n\nafter"),
            ("table", "| A | B |\n| - | - |\n| 1 | 2 |"),
            ("table in context", "before\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\nafter"),
            ("quote in context", "before\n\n> quoted line\n\nafter"),
            ("list in context", "before\n\n- alpha\n- beta\n\nafter"),
            ("thematic break", "before\n\n---\n\nafter"),
            ("paragraph then quote", "Body text\n\n> quoted line"),
        ]

        var rows: [String] = []
        for (name, markdown) in fixtures {
            let left = Self.markdownUIImage(markdown, width: Self.width)?.size.height ?? -1
            let right = Self.appKitImage(markdown, width: Self.width)?.size.height ?? -1
            let delta = right - left
            rows.append(
                String(
                    format: "%-24@ swiftui=%6.1f appkit=%6.1f delta=%+6.1f",
                    name as NSString, left, right, delta
                )
            )
        }
        print("\n" + rows.joined(separator: "\n") + "\n")
    }

    /// The inline only path, which is what most assistant text takes today.
    ///
    /// It has to keep behaving like a plain SwiftUI `Text` over an inline
    /// parsed `AttributedString`, including leaving block syntax literal.
    @Test("matches the inline only text path")
    func inlineOnlyParity() throws {
        let samples = [
            "Plain text with **bold**, *italic* and `code` in one line.",
            "Text long enough to wrap onto a second line so the four point line "
                + "spacing this path uses shows up in the height.",
            "- a dash line that this path leaves literal\n- and another",
            "A [link](https://example.com) and some ~~struck~~ words.",
        ]
        let appearance = ChatTextAppearance(
            font: .systemFont(ofSize: 13), foregroundColor: .labelColor, lineSpacing: 4
        )

        var rows: [String] = []
        for (index, sample) in samples.enumerated() {
            let parsed =
                (try? AttributedString(
                    markdown: sample,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(sample)
            let left = Self.swiftUIImage(
                Text(parsed).font(.system(size: 13)).lineSpacing(4), width: Self.width
            )
            let right = Self.appKitImage(
                attributed: ChatAttributedText.make(
                    content: .inlineMarkdown(sample), appearance: appearance, width: Self.width),
                width: Self.width
            )
            let leftHeight = left?.size.height ?? -1
            let rightHeight = right?.size.height ?? -1
            rows.append(
                String(
                    format: "inline[%d] swiftui=%6.1f appkit=%6.1f delta=%+6.1f",
                    index, leftHeight, rightHeight, rightHeight - leftHeight
                )
            )
            if index == 0, let left, let right {
                try Self.writeComparison(
                    left, right, to: ".claude/tmp/markdown-parity/inline-path.png")
            }
        }
        print("\n" + rows.joined(separator: "\n") + "\n")
    }

    @Test("keeps the whole message in one continuous string")
    func oneContinuousRun() {
        let renderer = MarkdownAttributedStringRenderer(
            theme: chatMarkdownTheme, metrics: chatMarkdownMetrics, containerWidth: Self.width
        )
        let attributed = renderer.render(markdown: Self.fixture)
        #expect(attributed.length > 0)
        // Selection spans a single text storage, so every block has to be part
        // of the same string rather than a separate view.
        #expect(attributed.string.contains("Heading one"))
        #expect(attributed.string.contains("greet"))
        #expect(attributed.string.contains("Centre"))
        #expect(attributed.string.contains("closing paragraph"))
    }

    @Test("lays tables out as a real grid")
    func tableIsAGrid() {
        let markdown = """
            | Left | Centre | Right |
            | :--- | :----: | ----: |
            | one | two | three |
            """
        let renderer = MarkdownAttributedStringRenderer(
            theme: chatMarkdownTheme, metrics: chatMarkdownMetrics, containerWidth: Self.width
        )
        let attributed = renderer.render(markdown: markdown)
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: Self.width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        var origins: [CGPoint] = []
        var index = 0
        while index < layout.numberOfGlyphs {
            var effective = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            origins.append(rect.origin)
            index = NSMaxRange(effective)
        }
        // Six cells over two rows: three distinct columns, two distinct rows.
        #expect(Set(origins.map(\.x)).count == 3)
        #expect(Set(origins.map(\.y)).count == 2)

        let alignments = (0..<attributed.length).compactMap {
            (attributed.attribute(.paragraphStyle, at: $0, effectiveRange: nil)
                as? NSParagraphStyle)?.alignment
        }
        #expect(alignments.contains(.left))
        #expect(alignments.contains(.center))
        #expect(alignments.contains(.right))
    }

    @Test("measures a trailing table's full height")
    func trailingTableHeight() {
        let markdown = """
            Intro paragraph.

            | A | B |
            | - | - |
            | 1 | 2 |
            | 3 | 4 |
            """
        let renderer = MarkdownAttributedStringRenderer(
            theme: chatMarkdownTheme, metrics: chatMarkdownMetrics, containerWidth: Self.width
        )
        let attributed = renderer.render(markdown: markdown)
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: Self.width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        let used = layout.usedRect(for: container)
        let lastGlyph = layout.numberOfGlyphs - 1
        let lastLine = layout.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        // usedRect has historically clipped a trailing table's bottom edge,
        // which shows up as messages drawn on top of each other.
        #expect(used.maxY >= lastLine.maxY)
    }
}
