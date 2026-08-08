import AppKit
import MarkdownUI

/// Draws the block decorations the markdown renderer marks up.
///
/// `NSTextBlock` only draws square corners, so a rounded code block background
/// or a rounded quote bar has to be painted here instead. Each decoration is
/// drawn from the union of its line fragments: a rect per fragment follows each
/// line's own used width, which turns a block fill into uneven stacked bands.
final class MarkdownLayoutManager: NSLayoutManager {

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        self.drawBlockDecorations(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawBlockDecorations(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = self.textStorage, let container = self.textContainers.first else {
            return
        }
        let characterRange = self.characterRange(
            forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(
            .markdownBlockDecoration, in: characterRange, options: []
        ) { value, range, _ in
            guard let decoration = value as? MarkdownBlockDecoration else { return }
            let glyphRange = self.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)

            var bounds = CGRect.null
            self.enumerateLineFragments(forGlyphRange: glyphRange) { _, used, _, _, _ in
                bounds = bounds.union(used)
            }
            guard !bounds.isNull, bounds.height > 0 else { return }

            let rect = self.decorationRect(
                decoration, textBounds: bounds, container: container
            ).offsetBy(dx: origin.x, dy: origin.y)
            guard rect.width > 0, rect.height > 0 else { return }

            decoration.color.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: decoration.cornerRadius,
                yRadius: decoration.cornerRadius
            ).fill()
        }
    }

    private func decorationRect(
        _ decoration: MarkdownBlockDecoration,
        textBounds: CGRect,
        container: NSTextContainer
    ) -> CGRect {
        let top = textBounds.minY - decoration.insets.top
        let height = textBounds.height + decoration.insets.top + decoration.insets.bottom

        switch decoration.kind {
        case .fill:
            // Spans the container rather than the text: a fill sized to the
            // widest line would step in and out with the code.
            let x = decoration.leadingOffset + decoration.insets.left
            let width = container.size.width - x - decoration.insets.right
            return CGRect(x: x, y: top, width: width, height: height)
        case .leadingBar:
            return CGRect(
                x: decoration.leadingOffset, y: top,
                width: decoration.thickness, height: height
            )
        }
    }
}
