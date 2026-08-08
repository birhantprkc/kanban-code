#if os(macOS)

  import AppKit
  import SwiftUI

  // kanban-code: inline rendering into AppKit attributes.
  //
  // `AttributedStringInlineRenderer` writes SwiftUI scope attributes (`Font`,
  // `Color`, `Text.LineStyle`), which an `NSAttributedString` drops on the
  // floor. This walks the same inline tree and the same `TextStyle`s, but
  // resolves them to `NSFont`/`NSColor` so the result can go into a text view.

  struct AppKitInlineRenderer {
    let baseURL: URL?
    let textStyles: InlineTextStyles

    /// Emits `attributes` folded over the inline tree.
    ///
    /// `attributes` must already carry a non-nil `fontProperties`: every font
    /// related `TextStyle` writes through `attributes.fontProperties?`, so a
    /// bare container silently discards every font, size and weight.
    func render(
      _ inlines: [InlineNode],
      attributes: AttributeContainer
    ) -> NSAttributedString {
      var state = State(attributes: attributes)
      for inline in inlines {
        self.render(inline, into: &state)
      }
      return state.result
    }

    private struct State {
      var result = NSMutableAttributedString()
      var attributes: AttributeContainer
      var shouldSkipNextWhitespace = false
    }

    private func render(_ inline: InlineNode, into state: inout State) {
      switch inline {
      case .text(let content):
        self.renderText(content, into: &state)
      case .softBreak:
        self.renderSoftBreak(into: &state)
      case .lineBreak:
        self.append("\u{2028}", into: &state)
      case .code(let content):
        self.renderStyled(self.textStyles.code, into: &state) {
          self.append(content, into: &$0)
        }
      case .html(let content):
        self.renderHTML(content, into: &state)
      case .emphasis(let children):
        self.renderStyled(self.textStyles.emphasis, children: children, into: &state)
      case .strong(let children):
        self.renderStyled(self.textStyles.strong, children: children, into: &state)
      case .strikethrough(let children):
        self.renderStyled(self.textStyles.strikethrough, children: children, into: &state)
      case .link(let destination, let children):
        self.renderLink(destination: destination, children: children, into: &state)
      case .image(let source, let children):
        // An inline image has no attachment to draw here, so it degrades to its
        // alt text linked to the source rather than disappearing.
        self.renderLink(destination: source, children: children, into: &state)
      }
    }

    private func renderText(_ text: String, into state: inout State) {
      var text = text
      if state.shouldSkipNextWhitespace {
        state.shouldSkipNextWhitespace = false
        text = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
      }
      self.append(text, into: &state)
    }

    private func renderSoftBreak(into state: inout State) {
      if state.shouldSkipNextWhitespace {
        state.shouldSkipNextWhitespace = false
      } else {
        self.append(" ", into: &state)
      }
    }

    private func renderHTML(_ html: String, into state: inout State) {
      let tag = HTMLTag(html)
      switch tag?.name.lowercased() {
      case "br":
        self.append("\u{2028}", into: &state)
        state.shouldSkipNextWhitespace = true
      default:
        self.renderText(html, into: &state)
      }
    }

    private func renderStyled(
      _ style: TextStyle, children: [InlineNode], into state: inout State
    ) {
      self.renderStyled(style, into: &state) { inner in
        for child in children {
          self.render(child, into: &inner)
        }
      }
    }

    private func renderStyled(
      _ style: TextStyle, into state: inout State, body: (inout State) -> Void
    ) {
      let saved = state.attributes
      style._collectAttributes(in: &state.attributes)
      body(&state)
      state.attributes = saved
    }

    private func renderLink(
      destination: String, children: [InlineNode], into state: inout State
    ) {
      let saved = state.attributes
      self.textStyles.link._collectAttributes(in: &state.attributes)
      state.attributes.link = URL(string: destination, relativeTo: self.baseURL)
      for child in children {
        self.render(child, into: &state)
      }
      state.attributes = saved
    }

    private func append(_ text: String, into state: inout State) {
      guard !text.isEmpty else { return }
      state.result.append(
        NSAttributedString(string: text, attributes: Self.appKitAttributes(state.attributes))
      )
    }

    // MARK: - Attribute resolution

    /// Converts the accumulated SwiftUI scope attributes into AppKit ones.
    static func appKitAttributes(
      _ container: AttributeContainer
    ) -> [NSAttributedString.Key: Any] {
      var out: [NSAttributedString.Key: Any] = [:]

      if let properties = container.fontProperties {
        out[.font] = self.resolveFont(properties)
      }
      if let color = container.foregroundColor {
        out[.foregroundColor] = NSColor(color)
      }
      if let color = container.backgroundColor {
        out[.backgroundColor] = NSColor(color)
      }
      if container.strikethroughStyle != nil {
        out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if container.underlineStyle != nil {
        out[.underlineStyle] = NSUnderlineStyle.single.rawValue
      }
      if let kern = container.kern {
        out[.kern] = kern
      }
      if let tracking = container.tracking {
        out[.tracking] = tracking
      }
      if let link = container.link {
        out[.link] = link
      }
      return out
    }

    /// Mirrors `Font.withProperties(_:)` in AppKit terms.
    static func resolveFont(_ properties: FontProperties) -> NSFont {
      let size = properties.scaledSize
      let weight = self.resolveWeight(properties.weight)

      var font: NSFont
      switch properties.family {
      case .system(let design):
        font = self.systemFont(size: size, weight: weight, design: design)
      case .custom(let name):
        font = NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
      }

      if properties.familyVariant == .monospaced {
        font = .monospacedSystemFont(ofSize: size, weight: weight)
      }
      if properties.digitVariant == .monospaced {
        font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
      }
      if properties.style == .italic {
        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      }
      return font
    }

    private static func systemFont(
      size: CGFloat, weight: NSFont.Weight, design: Font.Design
    ) -> NSFont {
      let base = NSFont.systemFont(ofSize: size, weight: weight)
      let systemDesign: NSFontDescriptor.SystemDesign?
      switch design {
      case .serif: systemDesign = .serif
      case .rounded: systemDesign = .rounded
      case .monospaced: systemDesign = .monospaced
      default: systemDesign = nil
      }
      guard let systemDesign,
        let descriptor = base.fontDescriptor.withDesign(systemDesign),
        let designed = NSFont(descriptor: descriptor, size: size)
      else {
        return base
      }
      return designed
    }

    private static func resolveWeight(_ weight: Font.Weight) -> NSFont.Weight {
      switch weight {
      case .ultraLight: return .ultraLight
      case .thin: return .thin
      case .light: return .light
      case .medium: return .medium
      case .semibold: return .semibold
      case .bold: return .bold
      case .heavy: return .heavy
      case .black: return .black
      default: return .regular
      }
    }
  }

#endif
