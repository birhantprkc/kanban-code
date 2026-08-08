import AppKit
import MarkdownUI

/// What a chat row draws.
///
/// The three cases mirror the paths the chat used to take through SwiftUI, and
/// they have to stay distinct: a message without block markdown is rendered
/// inline only today, which leaves things like `- item` as literal text.
enum ChatTextContent: Hashable {
    /// Full markdown, including headings, lists, quotes, code and tables.
    case markdown(String)
    /// Inline markdown only. Block syntax stays literal.
    case inlineMarkdown(String)
    /// No markdown at all.
    case plain(String)

    var rawText: String {
        switch self {
        case .markdown(let text), .inlineMarkdown(let text), .plain(let text): text
        }
    }
}

/// Font and colour for the non markdown cases, and for the text a markdown
/// message inherits.
struct ChatTextAppearance: Hashable {
    var font: NSFont
    var foregroundColor: NSColor
    var italic: Bool = false
    var lineSpacing: CGFloat = 0
}

/// A search match to paint behind the text.
struct ChatTextHighlight: Hashable {
    var query: String
    var isCurrentMatch: Bool
}

/// Builds the attributed string a chat row displays.
///
/// Results are cached: the chat re-renders on every poll and asks every
/// mounted message to rebuild, and a markdown parse plus table measurement per
/// message per pass shows up directly as scroll jank.
@MainActor
enum ChatAttributedText {

    private struct Key: Hashable {
        let content: ChatTextContent
        let appearance: ChatTextAppearance
        let highlight: ChatTextHighlight?
        let width: CGFloat
    }

    private static var cache = LRUCache<Key, NSAttributedString>(limit: 400)

    static func make(
        content: ChatTextContent,
        appearance: ChatTextAppearance,
        highlight: ChatTextHighlight? = nil,
        width: CGFloat
    ) -> NSAttributedString {
        // Table columns are sized from their content against the available
        // width, so the width belongs in the key.
        let key = Key(
            content: content, appearance: appearance, highlight: highlight,
            width: width.rounded()
        )
        if let cached = self.cache[key] { return cached }

        let result = self.build(
            content: content, appearance: appearance, highlight: highlight, width: width)
        self.cache[key] = result
        return result
    }

    private static func build(
        content: ChatTextContent,
        appearance: ChatTextAppearance,
        highlight: ChatTextHighlight?,
        width: CGFloat
    ) -> NSAttributedString {
        let result: NSMutableAttributedString
        switch content {
        case .markdown(let markdown):
            let renderer = MarkdownAttributedStringRenderer(
                theme: chatMarkdownTheme,
                metrics: chatMarkdownMetrics,
                containerWidth: max(width, 1)
            )
            result = NSMutableAttributedString(
                attributedString: renderer.render(markdown: markdown))
        case .inlineMarkdown(let markdown):
            result = self.inlineMarkdown(markdown, appearance: appearance)
        case .plain(let text):
            result = NSMutableAttributedString(
                string: text, attributes: self.plainAttributes(appearance))
        }

        if let highlight, !highlight.query.isEmpty {
            self.applyHighlight(highlight, to: result)
        }
        return result
    }

    // MARK: - Non markdown paths

    private static func plainAttributes(
        _ appearance: ChatTextAppearance
    ) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        // No trailing compensation here, unlike the block renderer. These paths
        // stand in for a single SwiftUI `Text`, where a newline is a line break
        // that line spacing applies across, not a block boundary.
        style.lineSpacing = appearance.lineSpacing
        return [
            .font: self.resolvedFont(appearance),
            .foregroundColor: appearance.foregroundColor,
            .paragraphStyle: style,
        ]
    }

    private static func resolvedFont(_ appearance: ChatTextAppearance) -> NSFont {
        guard appearance.italic else { return appearance.font }
        return NSFontManager.shared.convert(appearance.font, toHaveTrait: .italicFontMask)
    }

    /// Inline markdown through Foundation's parser, matching what the chat's
    /// lighter text path produces today.
    private static func inlineMarkdown(
        _ text: String, appearance: ChatTextAppearance
    ) -> NSMutableAttributedString {
        let base = self.plainAttributes(appearance)
        guard
            let parsed = try? AttributedString(
                markdown: text,
                options: .init(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        else {
            return NSMutableAttributedString(string: text, attributes: base)
        }

        let font = self.resolvedFont(appearance)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            guard !piece.isEmpty else { continue }
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []

            if intent.contains(.code) {
                // No chip behind it: this path feeds a plain SwiftUI `Text`
                // today, which styles a code run as monospaced and nothing more.
                attributes[.font] = NSFont.monospacedSystemFont(
                    ofSize: font.pointSize, weight: .regular)
            } else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty {
                    attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits)
                }
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link {
                attributes[.link] = url
            }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }

    // MARK: - Search highlighting

    private static func applyHighlight(
        _ highlight: ChatTextHighlight, to string: NSMutableAttributedString
    ) {
        let haystack = string.string.lowercased()
        let needle = highlight.query.lowercased()
        guard !needle.isEmpty else { return }

        let color: NSColor =
            highlight.isCurrentMatch
            ? NSColor.systemOrange.withAlphaComponent(0.4)
            : NSColor.systemYellow.withAlphaComponent(0.3)

        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let location = haystack.distance(from: haystack.startIndex, to: found.lowerBound)
            let length = haystack.distance(from: found.lowerBound, to: found.upperBound)
            let range = NSRange(location: location, length: length)
            if NSMaxRange(range) <= string.length {
                string.addAttribute(.backgroundColor, value: color, range: range)
            }
            searchStart = found.upperBound
        }
    }
}

/// A dictionary that evicts what was used least recently.
///
/// Dropping everything at once instead would stall a long conversation on the
/// pass right after the cache filled up.
struct LRUCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    subscript(key: Key) -> Value? {
        mutating get {
            guard let value = self.storage[key] else { return nil }
            self.touch(key)
            return value
        }
        set {
            guard let newValue else {
                self.storage[key] = nil
                self.order.removeAll { $0 == key }
                return
            }
            self.storage[key] = newValue
            self.touch(key)
            while self.order.count > self.limit {
                self.storage[self.order.removeFirst()] = nil
            }
        }
    }

    private mutating func touch(_ key: Key) {
        if let index = self.order.firstIndex(of: key) {
            self.order.remove(at: index)
        }
        self.order.append(key)
    }
}
