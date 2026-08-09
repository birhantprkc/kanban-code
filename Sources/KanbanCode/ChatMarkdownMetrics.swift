import AppKit
import MarkdownUI
import SwiftUI

/// Block geometry for `chatMarkdownTheme`, for the AppKit markdown renderer.
///
/// A `Theme` keeps its block styles as opaque view builders, so margins,
/// padding, backgrounds and bar widths cannot be read back off one. They are
/// restated here, and must stay in step with `chatMarkdownTheme` and with the
/// parts of MarkdownUI's GitHub theme that it inherits.
///
/// Sizes written as a ratio mirror the theme's `.em` units, which resolve
/// against the running font rather than the root size.
@MainActor
let chatMarkdownMetrics: MarkdownBlockMetrics = {
    let base: CGFloat = 13

    return MarkdownBlockMetrics(
        baseFontSize: base,
        // Reached only when neither side of a block boundary sets a margin,
        // which for this theme means one heading directly after another.
        defaultBlockSpacing: 16,
        paragraph: .init(
            relativeLineSpacing: 0.25,
            margin: .init(top: 0, bottom: 16)
        ),
        // The chat theme replaces h1 to h3 outright, dropping the GitHub
        // margins and dividers, and keeps them at body size so only the weight
        // separates them. h4 to h6 are inherited untouched.
        headings: [
            .init(paddingBottom: 2) { FontSize(base); FontWeight(.bold) },
            .init(paddingBottom: 2) { FontSize(base); FontWeight(.semibold) },
            .init(paddingBottom: 2) { FontSize(base); FontWeight(.medium) },
            .init(relativeLineSpacing: 0.125, margin: .init(top: 24, bottom: 16)) {
                FontWeight(.semibold)
            },
            .init(relativeLineSpacing: 0.125, margin: .init(top: 24, bottom: 16)) {
                FontWeight(.semibold)
                FontSize(.em(0.875))
            },
            .init(relativeLineSpacing: 0.125, margin: .init(top: 24, bottom: 16)) {
                FontWeight(.semibold)
                FontSize(.em(0.85))
                ForegroundColor(.markdownTertiaryText)
            },
        ],
        blockquote: .init(
            barWidth: round(0.2 * base),
            barCornerRadius: 6,
            barColor: .markdownBorder,
            leadingPadding: base,
            trailingPadding: base
        ) {
            ForegroundColor(.markdownSecondaryText)
        },
        codeBlock: .init(
            relativeLineSpacing: 0.225,
            padding: 16,
            backgroundColor: .markdownSecondaryBackground,
            cornerRadius: 6,
            margin: .init(top: 0, bottom: 16)
        ) {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
        },
        list: .init(
            markerRelativeWidth: 1.5,
            bulletRelativeDiameter: 1.0 / 3.0,
            itemMargin: .init(top: round(0.25 * base), bottom: nil),
            markerSpacing: 8
        ),
        table: .init(
            borderColor: .markdownBorder,
            borderWidth: 1,
            cellPaddingVertical: 6,
            cellPaddingHorizontal: 13,
            cellRelativeLineSpacing: 0.25,
            headerRowBackground: .markdownBackground,
            oddRowBackground: .markdownBackground,
            evenRowBackground: .markdownSecondaryBackground,
            margin: .init(top: 0, bottom: 16)
        ) {
            FontWeight(.semibold)
            BackgroundColor(nil)
        } cellTextStyle: {
            BackgroundColor(nil)
        },
        thematicBreak: .init(
            relativeThickness: 0.25,
            color: .markdownBorder,
            margin: .init(top: 24, bottom: 24)
        )
    )
}()

// MARK: - GitHub theme palette

/// The GitHub theme's colors, which it keeps `fileprivate`.
extension NSColor {
    static let markdownSecondaryText = dynamic(light: 0x6b6e_7bff, dark: 0x9294_a0ff)
    static let markdownTertiaryText = dynamic(light: 0x6b6e_7bff, dark: 0x6d70_7dff)
    static let markdownBackground = dynamic(light: 0xffff_ffff, dark: 0x1819_1dff)
    static let markdownSecondaryBackground = dynamic(light: 0xf7f7_f9ff, dark: 0x2526_2aff)
    static let markdownBorder = dynamic(light: 0xe4e4_e8ff, dark: 0x4244_4eff)

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
                ? NSColor(rgba: light) : NSColor(rgba: dark)
        }
    }

    fileprivate convenience init(rgba: UInt32) {
        self.init(
            srgbRed: CGFloat((rgba & 0xff00_0000) >> 24) / 255,
            green: CGFloat((rgba & 0x00ff_0000) >> 16) / 255,
            blue: CGFloat((rgba & 0x0000_ff00) >> 8) / 255,
            alpha: CGFloat(rgba & 0x0000_00ff) / 255
        )
    }
}

extension Color {
    fileprivate static let markdownSecondaryText = Color(nsColor: .markdownSecondaryText)
    fileprivate static let markdownTertiaryText = Color(nsColor: .markdownTertiaryText)
}
