#if os(macOS)

  import AppKit
  import SwiftUI

  // kanban-code: block geometry as data, for the AppKit renderer.
  //
  // `BlockStyle` erases its body to `AnyView`, so a block's margins, padding,
  // background, corner radius and bar widths cannot be read back off a `Theme`.
  // Those values live here as data. Anything that *is* expressible as a
  // `TextStyle` stays one, so a metrics value reads like the theme it mirrors
  // and goes through the same `_collectAttributes` fold.
  //
  // Sizes given as a ratio mirror `.em`, which resolves against the running
  // font rather than the root size.

  /// Vertical margins around a block.
  ///
  /// `nil` is meaningful: a boundary with no margin on either side falls back
  /// to a default gap, so an unset margin is not the same as zero.
  public struct MarkdownBlockMargin: Hashable {
    public var top: CGFloat?
    public var bottom: CGFloat?

    public init(top: CGFloat? = nil, bottom: CGFloat? = nil) {
      self.top = top
      self.bottom = bottom
    }

    public static let unspecified = MarkdownBlockMargin()

    /// Combines two margins by taking the larger of each non-nil edge, the way
    /// `BlockMarginsPreference` reduces margins over a block's whole subtree.
    public func merging(_ other: MarkdownBlockMargin) -> MarkdownBlockMargin {
      MarkdownBlockMargin(
        top: [self.top, other.top].compactMap { $0 }.max(),
        bottom: [self.bottom, other.bottom].compactMap { $0 }.max()
      )
    }
  }

  /// Everything the AppKit renderer needs that a `Theme` cannot surface.
  public struct MarkdownBlockMetrics {

    public struct Paragraph {
      public var relativeLineSpacing: CGFloat
      public var margin: MarkdownBlockMargin

      public init(relativeLineSpacing: CGFloat, margin: MarkdownBlockMargin) {
        self.relativeLineSpacing = relativeLineSpacing
        self.margin = margin
      }
    }

    public struct Heading {
      public var textStyle: TextStyle
      public var relativeLineSpacing: CGFloat
      public var margin: MarkdownBlockMargin
      /// Extra space inside the block, from a plain `.padding(.bottom, _:)`.
      public var paddingBottom: CGFloat

      public init(
        relativeLineSpacing: CGFloat = 0,
        margin: MarkdownBlockMargin = .unspecified,
        paddingBottom: CGFloat = 0,
        @TextStyleBuilder textStyle: () -> some TextStyle
      ) {
        self.textStyle = textStyle()
        self.relativeLineSpacing = relativeLineSpacing
        self.margin = margin
        self.paddingBottom = paddingBottom
      }
    }

    public struct Blockquote {
      public var textStyle: TextStyle
      public var barWidth: CGFloat
      public var barCornerRadius: CGFloat
      public var barColor: NSColor
      public var leadingPadding: CGFloat
      public var trailingPadding: CGFloat

      public init(
        barWidth: CGFloat,
        barCornerRadius: CGFloat,
        barColor: NSColor,
        leadingPadding: CGFloat,
        trailingPadding: CGFloat,
        @TextStyleBuilder textStyle: () -> some TextStyle
      ) {
        self.textStyle = textStyle()
        self.barWidth = barWidth
        self.barCornerRadius = barCornerRadius
        self.barColor = barColor
        self.leadingPadding = leadingPadding
        self.trailingPadding = trailingPadding
      }
    }

    public struct CodeBlock {
      public var textStyle: TextStyle
      public var relativeLineSpacing: CGFloat
      public var padding: CGFloat
      public var backgroundColor: NSColor
      public var cornerRadius: CGFloat
      public var margin: MarkdownBlockMargin

      public init(
        relativeLineSpacing: CGFloat,
        padding: CGFloat,
        backgroundColor: NSColor,
        cornerRadius: CGFloat,
        margin: MarkdownBlockMargin,
        @TextStyleBuilder textStyle: () -> some TextStyle
      ) {
        self.textStyle = textStyle()
        self.relativeLineSpacing = relativeLineSpacing
        self.padding = padding
        self.backgroundColor = backgroundColor
        self.cornerRadius = cornerRadius
        self.margin = margin
      }
    }

    public struct List {
      /// Width reserved for the marker, as a ratio of the item's font size.
      public var markerRelativeWidth: CGFloat
      /// Bullet glyph diameter, as a ratio of the item's font size.
      public var bulletRelativeDiameter: CGFloat
      public var itemMargin: MarkdownBlockMargin
      /// Gap between the marker and the item's text, matching the spacing a
      /// `Label` puts between its icon and title. Also the indent each nesting
      /// level adds, since nesting is the same `Label` one level deeper.
      public var markerSpacing: CGFloat

      public init(
        markerRelativeWidth: CGFloat,
        bulletRelativeDiameter: CGFloat,
        itemMargin: MarkdownBlockMargin,
        markerSpacing: CGFloat
      ) {
        self.markerRelativeWidth = markerRelativeWidth
        self.bulletRelativeDiameter = bulletRelativeDiameter
        self.itemMargin = itemMargin
        self.markerSpacing = markerSpacing
      }
    }

    public struct Table {
      public var headerTextStyle: TextStyle
      public var cellTextStyle: TextStyle
      public var borderColor: NSColor
      public var borderWidth: CGFloat
      public var cellPaddingVertical: CGFloat
      public var cellPaddingHorizontal: CGFloat
      public var cellRelativeLineSpacing: CGFloat
      /// Row fills. The header is its own value, then rows alternate starting
      /// with odd, so the first body row repeats the odd fill.
      public var headerRowBackground: NSColor?
      public var oddRowBackground: NSColor?
      public var evenRowBackground: NSColor?
      public var margin: MarkdownBlockMargin

      public init(
        borderColor: NSColor,
        borderWidth: CGFloat,
        cellPaddingVertical: CGFloat,
        cellPaddingHorizontal: CGFloat,
        cellRelativeLineSpacing: CGFloat,
        headerRowBackground: NSColor?,
        oddRowBackground: NSColor?,
        evenRowBackground: NSColor?,
        margin: MarkdownBlockMargin,
        @TextStyleBuilder headerTextStyle: () -> some TextStyle,
        @TextStyleBuilder cellTextStyle: () -> some TextStyle
      ) {
        self.headerTextStyle = headerTextStyle()
        self.cellTextStyle = cellTextStyle()
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.cellPaddingVertical = cellPaddingVertical
        self.cellPaddingHorizontal = cellPaddingHorizontal
        self.cellRelativeLineSpacing = cellRelativeLineSpacing
        self.headerRowBackground = headerRowBackground
        self.oddRowBackground = oddRowBackground
        self.evenRowBackground = evenRowBackground
        self.margin = margin
      }
    }

    public struct ThematicBreak {
      /// Line thickness as a ratio of the base font size.
      public var relativeThickness: CGFloat
      public var color: NSColor
      public var margin: MarkdownBlockMargin

      public init(relativeThickness: CGFloat, color: NSColor, margin: MarkdownBlockMargin) {
        self.relativeThickness = relativeThickness
        self.color = color
        self.margin = margin
      }
    }

    public var baseFontSize: CGFloat
    /// Gap used when neither side of a block boundary declares a margin, which
    /// is what SwiftUI's `.padding(.top, nil)` resolves to.
    public var defaultBlockSpacing: CGFloat

    public var paragraph: Paragraph
    /// Six entries, h1 through h6.
    public var headings: [Heading]
    public var blockquote: Blockquote
    public var codeBlock: CodeBlock
    public var list: List
    public var table: Table
    public var thematicBreak: ThematicBreak

    public init(
      baseFontSize: CGFloat,
      defaultBlockSpacing: CGFloat,
      paragraph: Paragraph,
      headings: [Heading],
      blockquote: Blockquote,
      codeBlock: CodeBlock,
      list: List,
      table: Table,
      thematicBreak: ThematicBreak
    ) {
      precondition(headings.count == 6, "headings must cover h1 through h6")
      self.baseFontSize = baseFontSize
      self.defaultBlockSpacing = defaultBlockSpacing
      self.paragraph = paragraph
      self.headings = headings
      self.blockquote = blockquote
      self.codeBlock = codeBlock
      self.list = list
      self.table = table
      self.thematicBreak = thematicBreak
    }
  }

#endif
