import AppKit
import SwiftUI

/// A read-only text view that renders a whole chat row as one selectable run.
///
/// SwiftUI selection is per `Text`, so a message split into per-block views can
/// only ever be selected one block at a time. A single text view lets a drag
/// run from the first heading to the last paragraph, through tables and code,
/// with the formatting intact.
struct SelectableMarkdownText: NSViewRepresentable {
    let content: ChatTextContent
    var appearance: ChatTextAppearance
    var highlight: ChatTextHighlight?

    func makeNSView(context: Context) -> WrappingTextView {
        WrappingTextView.make()
    }

    func updateNSView(_ nsView: WrappingTextView, context: Context) {
        nsView.configure(
            content: self.content, appearance: self.appearance, highlight: self.highlight)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: WrappingTextView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 1, width.isFinite else { return nil }
        nsView.configure(
            content: self.content, appearance: self.appearance, highlight: self.highlight)
        return nsView.fittingSize(forWidth: width)
    }

    /// Renders and measures itself, rebuilding whenever its width changes.
    ///
    /// The text depends on the width, because table columns are sized from
    /// their content against the space available. Building it once from the
    /// representable would freeze the layout at whatever width the view had
    /// before SwiftUI proposed one, which is none.
    final class WrappingTextView: NSTextView {
        static func make() -> WrappingTextView {
            // An explicit TextKit 1 stack. NSTextTable and NSTextAttachmentCell
            // are laid out by NSLayoutManager and by nothing in TextKit 2, and
            // a plain NSTextView(frame:) gives TextKit 2, where tables flatten.
            let storage = NSTextStorage()
            let layoutManager = MarkdownLayoutManager()
            let container = NSTextContainer(
                size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            )
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(container)

            let textView = WrappingTextView(frame: CGRect.zero, textContainer: container)
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.allowsUndo = false
            textView.isRichText = true
            textView.textContainerInset = CGSize.zero
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
            return textView
        }

        private var content: ChatTextContent = .plain("")
        private var textAppearance = ChatTextAppearance(
            font: .systemFont(ofSize: NSFont.systemFontSize), foregroundColor: .labelColor)
        private var highlight: ChatTextHighlight?
        private var renderedWidth: CGFloat = 0

        func configure(
            content: ChatTextContent,
            appearance: ChatTextAppearance,
            highlight: ChatTextHighlight?
        ) {
            let changed =
                content != self.content || appearance != self.textAppearance
                || highlight != self.highlight
            self.content = content
            self.textAppearance = appearance
            self.highlight = highlight
            if changed { self.renderedWidth = 0 }
            self.render(width: self.bounds.width)
        }

        func fittingSize(forWidth width: CGFloat) -> CGSize {
            self.render(width: width)
            let attributed = self.attributedText(width: width)
            let size = ChatTextMeasurement.size(of: attributed, width: width)
            // Report the text's own width, not the whole proposal. A short row
            // that claims the full width cannot be centred by its container,
            // which is how system notices are laid out.
            return CGSize(width: min(width, size.width), height: size.height)
        }

        private func attributedText(width: CGFloat) -> NSAttributedString {
            ChatAttributedText.make(
                content: self.content, appearance: self.textAppearance,
                highlight: self.highlight, width: width
            )
        }

        private func render(width: CGFloat) {
            guard width > 1, abs(width - self.renderedWidth) > 0.5 else { return }
            self.renderedWidth = width

            let attributed = self.attributedText(width: width)
            guard self.textStorage?.isEqual(to: attributed) != true else { return }

            // Chat polling re-renders live messages, so a drag in progress has
            // to survive the swap rather than being dropped mid selection.
            let selection = self.selectedRanges
            self.textStorage?.setAttributedString(attributed)
            let length = self.textStorage?.length ?? 0
            if selection.allSatisfy({ NSMaxRange($0.rangeValue) <= length }) {
                self.selectedRanges = selection
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            self.render(width: newSize.width)
        }

        /// Scrolling belongs to the surrounding chat scroll view.
        override func scrollWheel(with event: NSEvent) {
            self.nextResponder?.scrollWheel(with: event)
        }
    }
}

/// Measures attributed text off screen, memoised per text and width.
///
/// Every mounted message is asked for its size on each layout pass, so an
/// uncached layout here shows up directly as scroll jank.
@MainActor
enum ChatTextMeasurement {
    private struct Key: Hashable {
        let text: String
        let length: Int
        let width: CGFloat
    }

    private static var cache = LRUCache<Key, CGSize>(limit: 2_000)

    static func size(of attributed: NSAttributedString, width: CGFloat) -> CGSize {
        let rounded = width.rounded()
        let key = Key(text: attributed.string, length: attributed.length, width: rounded)
        if let cached = self.cache[key] { return cached }
        let measured = self.measure(attributed, width: rounded)
        self.cache[key] = measured
        return measured
    }

    private static func measure(_ attributed: NSAttributedString, width: CGFloat) -> CGSize {
        // Measure on a detached stack. The live view's container width tracks a
        // frame SwiftUI has not set during the sizing pass, so heights come
        // back short and messages end up drawn on top of each other.
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(
            size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        let layoutManager = MarkdownLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let used = layoutManager.usedRect(for: container)
        // usedRect can stop short of a trailing table's bottom edge, which is
        // what draws one message over the next.
        var height = used.maxY
        if layoutManager.numberOfGlyphs > 0 {
            let last = layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil)
            height = max(height, last.maxY)
        }
        return CGSize(width: ceil(used.maxX), height: ceil(height))
    }
}
