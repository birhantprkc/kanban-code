#if os(macOS)

  import AppKit

  // kanban-code: block decorations that TextKit cannot express on its own.
  //
  // `NSTextBlock` draws square corners only, so a rounded code block background
  // or a rounded quote bar has to be painted by a layout manager. These
  // attributes mark the ranges to paint; `MarkdownLayoutManager` does the
  // drawing.

  extension NSAttributedString.Key {
    /// A ``MarkdownBlockDecoration`` painted behind a whole block.
    public static let markdownBlockDecoration = NSAttributedString.Key(
      "markdownBlockDecoration"
    )
  }

  /// A shape drawn behind a run of block level text.
  ///
  /// Drawn from the union of the run's line fragments rather than per fragment:
  /// a per fragment rect follows each line's own used width, which turns a code
  /// block background into uneven stacked bands.
  public final class MarkdownBlockDecoration: NSObject {
    public enum Kind {
      /// Fills the block's full width.
      case fill
      /// Draws a vertical bar along the leading edge.
      case leadingBar
    }

    public let kind: Kind
    public let color: NSColor
    public let cornerRadius: CGFloat
    /// Bar thickness, used by ``Kind/leadingBar``.
    public let thickness: CGFloat
    /// How far the shape extends past the text on each edge.
    public let insets: NSEdgeInsets
    /// Distance from the container's leading edge to the shape.
    public let leadingOffset: CGFloat

    public init(
      kind: Kind,
      color: NSColor,
      cornerRadius: CGFloat = 0,
      thickness: CGFloat = 0,
      insets: NSEdgeInsets = NSEdgeInsets(),
      leadingOffset: CGFloat = 0
    ) {
      self.kind = kind
      self.color = color
      self.cornerRadius = cornerRadius
      self.thickness = thickness
      self.insets = insets
      self.leadingOffset = leadingOffset
    }
  }

  /// Draws a markdown thematic break as a line spanning the text width.
  ///
  /// Sizing from the line fragment keeps it correct when the view is resized,
  /// which a fixed width attachment cannot do.
  public final class MarkdownRuleAttachmentCell: NSTextAttachmentCell {
    private let color: NSColor
    private let thickness: CGFloat

    public init(color: NSColor, thickness: CGFloat) {
      self.color = color
      self.thickness = thickness
      super.init()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    public override func cellFrame(
      for textContainer: NSTextContainer,
      proposedLineFragment lineFrag: NSRect,
      glyphPosition position: NSPoint,
      characterIndex charIndex: Int
    ) -> NSRect {
      NSRect(x: 0, y: 0, width: max(lineFrag.width - position.x, 0), height: self.thickness)
    }

    public override func cellSize() -> NSSize {
      NSSize(width: 0, height: self.thickness)
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
      self.color.setFill()
      cellFrame.fill()
    }
  }

#endif
