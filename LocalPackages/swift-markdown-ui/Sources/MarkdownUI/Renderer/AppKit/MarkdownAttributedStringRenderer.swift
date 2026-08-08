#if os(macOS)

  import AppKit
  import SwiftUI

  // kanban-code: renders markdown into a single NSAttributedString.
  //
  // The SwiftUI path gives every block its own view, and a text selection
  // cannot span sibling views, so a drag stops at the first block boundary.
  // One attributed string in one text view is one selection domain, and
  // NSTextTable keeps real tables inside it, so a selection runs through
  // tables too.

  /// Renders markdown into one attributed string using a ``Theme`` for inline
  /// styling and ``MarkdownBlockMetrics`` for block geometry.
  ///
  /// The result depends on `containerWidth`, because table columns are sized
  /// from their content the way SwiftUI's `Grid` sizes them.
  public struct MarkdownAttributedStringRenderer {
    public var theme: Theme
    public var metrics: MarkdownBlockMetrics
    public var baseURL: URL?
    public var containerWidth: CGFloat

    public init(
      theme: Theme,
      metrics: MarkdownBlockMetrics,
      baseURL: URL? = nil,
      containerWidth: CGFloat
    ) {
      self.theme = theme
      self.metrics = metrics
      self.baseURL = baseURL
      self.containerWidth = containerWidth
    }

    public func render(markdown: String) -> NSAttributedString {
      self.render(blocks: [BlockNode](markdown: markdown))
    }

    func render(blocks: [BlockNode]) -> NSAttributedString {
      let result = self.renderBlocks(blocks, context: self.rootContext)
      // A trailing newline would add an empty last line to every message.
      while result.string.hasSuffix("\n") {
        result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
      }
      return result
    }

    // MARK: - Context

    private struct Context {
      var attributes: AttributeContainer
      /// Leading indent accumulated from list nesting and quote padding.
      var indent: CGFloat
      /// Trailing indent, as a negative `tailIndent` would express it.
      var trailingIndent: CGFloat
      var tight: Bool
      var listLevel: Int
      /// Width still available for content at this nesting depth.
      var availableWidth: CGFloat
    }

    private var rootContext: Context {
      var attributes = AttributeContainer()
      // Seed the font properties: every font related TextStyle writes through
      // `attributes.fontProperties?`, so without this they silently no-op.
      attributes.fontProperties = FontProperties(size: self.metrics.baseFontSize)
      self.theme.text._collectAttributes(in: &attributes)
      return Context(
        attributes: attributes,
        indent: 0,
        trailingIndent: 0,
        tight: false,
        listLevel: 0,
        availableWidth: self.containerWidth
      )
    }

    private var inlineTextStyles: InlineTextStyles {
      .init(
        code: self.theme.code,
        emphasis: self.theme.emphasis,
        strong: self.theme.strong,
        strikethrough: self.theme.strikethrough,
        link: self.theme.link
      )
    }

    private func inlineRenderer() -> AppKitInlineRenderer {
      .init(baseURL: self.baseURL, textStyles: self.inlineTextStyles)
    }

    private func font(_ context: Context) -> NSFont {
      AppKitInlineRenderer.resolveFont(
        context.attributes.fontProperties ?? FontProperties(size: self.metrics.baseFontSize)
      )
    }

    private func fontSize(_ context: Context) -> CGFloat {
      context.attributes.fontProperties?.scaledSize ?? self.metrics.baseFontSize
    }

    // MARK: - Block sequence

    private func renderBlocks(
      _ blocks: [BlockNode], context: Context
    ) -> NSMutableAttributedString {
      let out = NSMutableAttributedString()
      var previous: MarkdownBlockMargin?

      for (index, block) in blocks.enumerated() {
        let margin = self.margin(for: block)
        let gap: CGFloat
        if index == 0 {
          gap = 0
        } else {
          let above: CGFloat? = context.tight ? 0 : previous?.bottom
          let candidates = [margin.top, above].compactMap { $0 }
          gap = candidates.max() ?? self.metrics.defaultBlockSpacing
        }
        out.append(self.render(block: block, context: context, spacingBefore: gap))
        previous = margin
      }
      return out
    }

    /// A block's margins, reduced over its subtree the way the block margin
    /// preference is: a quote or list item inherits its children's margins.
    private func margin(for block: BlockNode) -> MarkdownBlockMargin {
      var margin: MarkdownBlockMargin
      switch block {
      case .paragraph, .htmlBlock:
        margin = self.metrics.paragraph.margin
      case .heading(let level, _):
        margin = self.metrics.headings[self.headingIndex(level)].margin
      case .codeBlock:
        margin = self.metrics.codeBlock.margin
      case .table:
        margin = self.metrics.table.margin
      case .thematicBreak:
        margin = self.metrics.thematicBreak.margin
      case .blockquote:
        margin = .unspecified
      case .bulletedList, .numberedList, .taskList:
        margin = self.metrics.list.itemMargin
      }
      for child in block.children {
        margin = margin.merging(self.margin(for: child))
      }
      return margin
    }

    private func headingIndex(_ level: Int) -> Int {
      min(max(level, 1), self.metrics.headings.count) - 1
    }

    // MARK: - Blocks

    private func render(
      block: BlockNode, context: Context, spacingBefore: CGFloat
    ) -> NSAttributedString {
      switch block {
      case .paragraph(let content):
        return self.renderParagraph(content, context: context, spacingBefore: spacingBefore)
      case .htmlBlock(let content):
        return self.renderParagraph(
          [.text(content.hasSuffix("\n") ? String(content.dropLast()) : content)],
          context: context, spacingBefore: spacingBefore
        )
      case .heading(let level, let content):
        return self.renderHeading(
          level: level, content: content, context: context, spacingBefore: spacingBefore)
      case .blockquote(let children):
        return self.renderBlockquote(children, context: context, spacingBefore: spacingBefore)
      case .codeBlock(_, let content):
        return self.renderCodeBlock(content, context: context, spacingBefore: spacingBefore)
      case .bulletedList(let isTight, let items):
        return self.renderList(
          items: items, markers: self.bulletMarkers(items.count, context: context),
          isTight: isTight, context: context, spacingBefore: spacingBefore)
      case .numberedList(let isTight, let start, let items):
        return self.renderList(
          items: items,
          markers: (0..<items.count).map { .text("\(start + $0).") },
          isTight: isTight, context: context, spacingBefore: spacingBefore)
      case .taskList(let isTight, let items):
        return self.renderList(
          items: items.map { RawListItem(children: $0.children) },
          markers: items.map { .symbol($0.isCompleted ? "checkmark.square.fill" : "square") },
          isTight: isTight, context: context, spacingBefore: spacingBefore)
      case .table(let alignments, let rows):
        return self.renderTable(
          alignments: alignments, rows: rows, context: context, spacingBefore: spacingBefore)
      case .thematicBreak:
        return self.renderThematicBreak(context: context, spacingBefore: spacingBefore)
      }
    }

    private func renderParagraph(
      _ content: [InlineNode], context: Context, spacingBefore: CGFloat
    ) -> NSAttributedString {
      let style = self.paragraphStyle(context: context, spacingBefore: spacingBefore)
      self.applyLineSpacing(
        self.relative(self.metrics.paragraph.relativeLineSpacing, context: context), to: style)
      return self.line(content, context: context, style: style)
    }

    private func renderHeading(
      level: Int, content: [InlineNode], context: Context, spacingBefore: CGFloat
    ) -> NSAttributedString {
      let spec = self.metrics.headings[self.headingIndex(level)]
      var context = context
      spec.textStyle._collectAttributes(in: &context.attributes)

      let style = self.paragraphStyle(context: context, spacingBefore: spacingBefore)
      style.paragraphSpacing = spec.paddingBottom
      self.applyLineSpacing(
        self.relative(spec.relativeLineSpacing, context: context), to: style)
      return self.line(content, context: context, style: style)
    }

    private func renderBlockquote(
      _ children: [BlockNode], context: Context, spacingBefore: CGFloat
    ) -> NSAttributedString {
      let spec = self.metrics.blockquote
      var inner = context
      spec.textStyle._collectAttributes(in: &inner.attributes)
      let barSpace = spec.barWidth + spec.leadingPadding
      inner.indent += barSpace
      inner.trailingIndent += spec.trailingPadding
      inner.availableWidth -= barSpace + spec.trailingPadding

      let body = self.renderBlocks(children, context: inner)
      guard body.length > 0 else { return body }

      self.applySpacingBefore(spacingBefore, to: body)
      self.decorate(
        body,
        with: MarkdownBlockDecoration(
          kind: .leadingBar,
          color: spec.barColor,
          cornerRadius: spec.barCornerRadius,
          thickness: spec.barWidth,
          leadingOffset: context.indent
        )
      )
      return body
    }

    private func renderCodeBlock(
      _ content: String, context: Context, spacingBefore: CGFloat
    ) -> NSAttributedString {
      let spec = self.metrics.codeBlock
      var inner = context
      spec.textStyle._collectAttributes(in: &inner.attributes)

      let style = self.paragraphStyle(context: inner, spacingBefore: spacingBefore)
      self.applyLineSpacing(self.relative(spec.relativeLineSpacing, context: inner), to: style)
      style.firstLineHeadIndent += spec.padding
      style.headIndent += spec.padding
      style.tailIndent -= spec.padding
      // Padding has to be real layout space, not just an inset on the shape
      // drawn behind the text, or the background overlaps its neighbours.
      style.paragraphSpacingBefore += spec.padding
      style.paragraphSpacing += spec.padding

      // Line separators rather than newlines: a newline would start a new
      // paragraph, repeating the block's spacing on every line of code.
      var code = content
      while code.hasSuffix("\n") { code.removeLast() }
      let joined = code.replacingOccurrences(of: "\n", with: "\u{2028}")

      var attributes = AppKitInlineRenderer.appKitAttributes(inner.attributes)
      attributes[.paragraphStyle] = style
      let out = NSMutableAttributedString(string: joined + "\n", attributes: attributes)
      self.decorate(
        out,
        with: MarkdownBlockDecoration(
          kind: .fill,
          color: spec.backgroundColor,
          cornerRadius: spec.cornerRadius,
          insets: NSEdgeInsets(
            top: spec.padding, left: 0, bottom: spec.padding, right: 0
          ),
          leadingOffset: context.indent
        )
      )
      return out
    }

    private func renderThematicBreak(
      context: Context, spacingBefore: CGFloat
    ) -> NSAttributedString {
      let spec = self.metrics.thematicBreak
      let thickness = max(1, round(spec.relativeThickness * self.fontSize(context)))
      let attachment = NSTextAttachment()
      attachment.attachmentCell = MarkdownRuleAttachmentCell(
        color: spec.color, thickness: thickness)

      let out = NSMutableAttributedString(attachment: attachment)
      out.append(NSAttributedString(string: "\n"))
      out.addAttribute(
        .paragraphStyle,
        value: self.paragraphStyle(context: context, spacingBefore: spacingBefore),
        range: NSRange(location: 0, length: out.length)
      )
      return out
    }

    // MARK: - Lists

    private enum ListMarker {
      case text(String)
      case symbol(String)
    }

    private func bulletMarkers(_ count: Int, context: Context) -> [ListMarker] {
      // Matches `.discCircleSquare`, which picks by nesting depth.
      let names = ["circle.fill", "circle", "square.fill"]
      let name = names[min(max(context.listLevel, 0), names.count - 1)]
      return Array(repeating: .symbol(name), count: count)
    }

    private func renderList(
      items: [RawListItem],
      markers: [ListMarker],
      isTight: Bool,
      context: Context,
      spacingBefore: CGFloat
    ) -> NSAttributedString {
      let spec = self.metrics.list
      let size = self.fontSize(context)
      let baseMarkerWidth = round(spec.markerRelativeWidth * size)
      let markerStrings = markers.map { self.markerString($0, context: context) }
      let widest = markerStrings.map { ceil($0.size().width) }.max() ?? 0
      let markerWidth = max(baseMarkerWidth, widest)
      let contentIndent = markerWidth + spec.markerSpacing

      var inner = context
      inner.tight = isTight
      inner.listLevel = context.listLevel + 1
      inner.indent = context.indent + contentIndent
      inner.availableWidth = context.availableWidth - contentIndent

      let out = NSMutableAttributedString()
      var previous: MarkdownBlockMargin?

      for (index, item) in items.enumerated() {
        var margin = spec.itemMargin
        for child in item.children {
          margin = margin.merging(self.margin(for: child))
        }
        let gap: CGFloat
        if index == 0 {
          gap = spacingBefore
        } else {
          let above: CGFloat? = isTight ? 0 : previous?.bottom
          gap = [margin.top, above].compactMap { $0 }.max()
            ?? self.metrics.defaultBlockSpacing
        }

        let body = self.renderBlocks(item.children, context: inner)
        guard body.length > 0 else { continue }
        self.applySpacingBefore(gap, to: body)
        self.insertMarker(
          markerStrings[index], into: body, context: context,
          markerWidth: markerWidth, contentIndent: contentIndent
        )
        out.append(body)
        previous = margin
      }
      return out
    }

    private func markerString(_ marker: ListMarker, context: Context) -> NSAttributedString {
      var attributes = AppKitInlineRenderer.appKitAttributes(context.attributes)
      switch marker {
      case .text(let text):
        attributes[.font] = NSFont.monospacedDigitSystemFont(
          ofSize: self.fontSize(context),
          weight: context.attributes.fontProperties.map {
            AppKitInlineRenderer.resolveFont($0).weightValue
          } ?? .regular
        )
        return NSAttributedString(string: text, attributes: attributes)
      case .symbol(let name):
        let spec = self.metrics.list
        let pointSize = round(spec.bulletRelativeDiameter * self.fontSize(context))
        guard
          let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        else {
          return NSAttributedString(string: "\u{2022}", attributes: attributes)
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let font = self.font(context)
        // Sit the glyph on the first line's optical centre.
        let centre = font.capHeight / 2
        attachment.bounds = NSRect(
          x: 0, y: centre - image.size.height / 2,
          width: image.size.width, height: image.size.height
        )
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttributes(
          attributes.filter { $0.key == .foregroundColor },
          range: NSRange(location: 0, length: out.length)
        )
        return out
      }
    }

    /// Prefixes the item's first line with its marker in a right aligned
    /// column, and indents everything after it to the content column.
    private func insertMarker(
      _ marker: NSAttributedString,
      into body: NSMutableAttributedString,
      context: Context,
      markerWidth: CGFloat,
      contentIndent: CGFloat
    ) {
      let existing =
        body.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

      let prefix = NSMutableAttributedString(string: "\t")
      prefix.append(marker)
      prefix.append(NSAttributedString(string: "\t"))
      body.insert(prefix, at: 0)

      // The style has to be applied after the prefix goes in. A paragraph takes
      // its style from its first character, so inserting unstyled text at the
      // front would drop the indents and the spacing for the whole line.
      let newline = (body.string as NSString).range(of: "\n")
      let firstLength = newline.location == NSNotFound ? body.length : NSMaxRange(newline)

      let style =
        (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
      style.firstLineHeadIndent = context.indent
      style.headIndent = context.indent + contentIndent
      style.tabStops = [
        NSTextTab(textAlignment: .right, location: context.indent + markerWidth),
        NSTextTab(textAlignment: .left, location: context.indent + contentIndent),
      ]
      body.addAttribute(
        .paragraphStyle, value: style, range: NSRange(location: 0, length: firstLength))
    }

    // MARK: - Tables

    private func renderTable(
      alignments: [RawTableColumnAlignment],
      rows: [RawTableRow],
      context: Context,
      spacingBefore: CGFloat
    ) -> NSAttributedString {
      let spec = self.metrics.table
      let columnCount = alignments.count
      guard columnCount > 0, !rows.isEmpty else { return NSAttributedString() }

      let table = NSTextTable()
      table.numberOfColumns = columnCount
      table.layoutAlgorithm = .automaticLayoutAlgorithm
      table.collapsesBorders = true
      // A GFM table routinely has empty cells; hiding them would collapse rows.
      table.hidesEmptyCells = false
      // The gap goes on the table itself. Putting it on the first cell's
      // paragraph would grow that cell and push its text down the row.
      table.setWidth(spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)

      let cells = self.tableCellStrings(rows: rows, columnCount: columnCount, context: context)
      let widths = self.columnWidths(cells: cells, columnCount: columnCount, context: context)

      let out = NSMutableAttributedString()
      for (rowIndex, row) in cells.enumerated() {
        for (columnIndex, cell) in row.enumerated() {
          let block = NSTextTableBlock(
            table: table, startingRow: rowIndex, rowSpan: 1,
            startingColumn: columnIndex, columnSpan: 1
          )
          block.setBorderColor(spec.borderColor)
          block.setWidth(spec.borderWidth, type: .absoluteValueType, for: .border)
          block.setWidth(
            spec.cellPaddingVertical, type: .absoluteValueType, for: .padding, edge: .minY)
          block.setWidth(
            spec.cellPaddingVertical, type: .absoluteValueType, for: .padding, edge: .maxY)
          block.setWidth(
            spec.cellPaddingHorizontal, type: .absoluteValueType, for: .padding, edge: .minX)
          block.setWidth(
            spec.cellPaddingHorizontal, type: .absoluteValueType, for: .padding, edge: .maxX)
          block.setValue(widths[columnIndex], type: .absoluteValueType, for: .width)
          block.verticalAlignment = .topAlignment
          block.backgroundColor = self.rowBackground(rowIndex, spec: spec)

          let style = NSMutableParagraphStyle()
          style.textBlocks = [block]
          style.alignment = self.alignment(alignments[columnIndex])
          self.applyLineSpacing(
            self.relative(spec.cellRelativeLineSpacing, context: context), to: style)

          let paragraph = NSMutableAttributedString(attributedString: cell)
          paragraph.append(NSAttributedString(string: "\n"))
          paragraph.addAttribute(
            .paragraphStyle, value: style,
            range: NSRange(location: 0, length: paragraph.length)
          )
          out.append(paragraph)
        }
      }
      return out
    }

    private func tableCellStrings(
      rows: [RawTableRow], columnCount: Int, context: Context
    ) -> [[NSAttributedString]] {
      let spec = self.metrics.table
      let renderer = self.inlineRenderer()
      return rows.enumerated().map { rowIndex, row in
        var cellContext = context
        (rowIndex == 0 ? spec.headerTextStyle : spec.cellTextStyle)
          ._collectAttributes(in: &cellContext.attributes)
        return (0..<columnCount).map { columnIndex in
          let content = columnIndex < row.cells.count ? row.cells[columnIndex].content : []
          return renderer.render(content, attributes: cellContext.attributes)
        }
      }
    }

    /// Sizes columns from their content, then shrinks them to fit if the
    /// natural widths overflow, which is how a SwiftUI `Grid` behaves.
    private func columnWidths(
      cells: [[NSAttributedString]], columnCount: Int, context: Context
    ) -> [CGFloat] {
      let spec = self.metrics.table
      var natural = [CGFloat](repeating: 0, count: columnCount)
      for row in cells {
        for (index, cell) in row.enumerated() {
          natural[index] = max(natural[index], ceil(cell.size().width))
        }
      }

      let chrome =
        CGFloat(columnCount) * (2 * spec.cellPaddingHorizontal + spec.borderWidth)
        + spec.borderWidth
      let available = max(context.availableWidth - chrome, CGFloat(columnCount))
      let total = natural.reduce(0, +)
      guard total > available else { return natural }

      // Shrink wide columns hardest, but never below a readable floor.
      let floor = min(3 * self.fontSize(context), available / CGFloat(columnCount))
      var widths = natural
      var flexible = (0..<columnCount).filter { natural[$0] > floor }
      var deficit = total - available
      while deficit > 0.5, !flexible.isEmpty {
        let flexibleTotal = flexible.reduce(0) { $0 + widths[$1] - floor }
        guard flexibleTotal > 0 else { break }
        for index in flexible {
          let share = (widths[index] - floor) / flexibleTotal
          widths[index] = max(floor, widths[index] - deficit * share)
        }
        let newTotal = widths.reduce(0, +)
        deficit = newTotal - available
        flexible = flexible.filter { widths[$0] > floor + 0.5 }
      }
      return widths.map { max(1, $0.rounded(.down)) }
    }

    /// The header keeps its own fill and body rows then alternate starting from
    /// odd, so the first body row repeats the header's fill.
    private func rowBackground(
      _ row: Int, spec: MarkdownBlockMetrics.Table
    ) -> NSColor? {
      guard row > 0 else { return spec.headerRowBackground }
      return row.isMultiple(of: 2) ? spec.evenRowBackground : spec.oddRowBackground
    }

    private func alignment(_ alignment: RawTableColumnAlignment) -> NSTextAlignment {
      switch alignment {
      case .none, .left: return .left
      case .center: return .center
      case .right: return .right
      }
    }

    // MARK: - Helpers

    private func line(
      _ content: [InlineNode], context: Context, style: NSParagraphStyle
    ) -> NSAttributedString {
      let out = NSMutableAttributedString(
        attributedString: self.inlineRenderer().render(content, attributes: context.attributes)
      )
      out.append(
        NSAttributedString(
          string: "\n", attributes: AppKitInlineRenderer.appKitAttributes(context.attributes))
      )
      out.addAttribute(
        .paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
      return out
    }

    private func paragraphStyle(
      context: Context, spacingBefore: CGFloat
    ) -> NSMutableParagraphStyle {
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byWordWrapping
      style.firstLineHeadIndent = context.indent
      style.headIndent = context.indent
      style.tailIndent = context.trailingIndent == 0 ? 0 : -context.trailingIndent
      // The gap goes entirely in `paragraphSpacingBefore`: AppKit sums
      // spacing on both sides of a boundary, while block margins collapse.
      style.paragraphSpacingBefore = spacingBefore
      style.paragraphSpacing = 0
      return style
    }

    /// Marks a run for decoration, leaving off its paragraph terminator.
    ///
    /// A trailing newline belongs to the block but lays out on the line that
    /// follows it, so including it would stretch the shape over the next block.
    private func decorate(
      _ string: NSMutableAttributedString, with decoration: MarkdownBlockDecoration
    ) {
      var length = string.length
      if length > 0, (string.string as NSString).character(at: length - 1) == 10 {
        length -= 1
      }
      guard length > 0 else { return }
      string.addAttribute(
        .markdownBlockDecoration, value: decoration,
        range: NSRange(location: 0, length: length)
      )
    }

    /// Adds a gap above the first paragraph of an already rendered run.
    private func applySpacingBefore(
      _ spacing: CGFloat, to string: NSMutableAttributedString
    ) {
      guard spacing != 0, string.length > 0 else { return }
      var range = NSRange(location: 0, length: 0)
      guard
        let existing = string.attribute(.paragraphStyle, at: 0, effectiveRange: &range)
          as? NSParagraphStyle,
        let style = existing.mutableCopy() as? NSMutableParagraphStyle
      else { return }
      style.paragraphSpacingBefore = spacing
      string.addAttribute(.paragraphStyle, value: style, range: range)
    }

    /// Sets line spacing and takes it back off the paragraph's trailing edge.
    ///
    /// TextKit leaves a line's worth of space under a paragraph's last line,
    /// where SwiftUI's `lineSpacing` only separates lines. Without this every
    /// paragraph stands one gap taller than the view it replaces.
    private func applyLineSpacing(_ spacing: CGFloat, to style: NSMutableParagraphStyle) {
      guard spacing != 0 else { return }
      style.lineSpacing = spacing
      style.paragraphSpacing -= spacing
    }

    private func relative(_ ratio: CGFloat, context: Context) -> CGFloat {
      guard ratio != 0 else { return 0 }
      return round(ratio * self.fontSize(context))
    }
  }

  extension NSFont {
    fileprivate var weightValue: NSFont.Weight {
      let traits = self.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
      return (traits?[.weight] as? NSNumber).map { NSFont.Weight($0.doubleValue) } ?? .regular
    }
  }

#endif
