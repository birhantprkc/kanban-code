import Foundation

/// Pure URL/issue-ref detection for the terminal's cmd+hover/cmd+click layer.
/// Extracted from the NSView so the matching rules are unit-testable.
enum TerminalURLDetector {
    struct Detection: Equatable {
        let url: String
        let colStart: Int
        let colEnd: Int
    }

    private static let urlRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"https?://[^\s\x00<>\"'\])\}]+"#,
            options: []
        )
    }()

    /// Matches owner/repo#123 or bare #123 (GitHub issue/PR references).
    /// Lookbehind excludes matches inside URLs, hex colors, or HTML entities.
    private static let issueRefRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?<![&/a-zA-Z0-9])(?:[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)?#\d+"#,
            options: []
        )
    }()

    /// Find a clickable URL or GitHub issue/PR reference covering `col` in a
    /// terminal row's text. `col` maps 1:1 to UTF-16 offsets for the ASCII-ish
    /// content we match on.
    static func detect(in text: String, col: Int, githubBaseURL: String?) -> Detection? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if let regex = urlRegex {
            for match in regex.matches(in: text, range: fullRange) {
                // Sentence punctuation glued to the URL is not part of it:
                // "…/pull/769." or "…/wiki/page, with…". Mirrors the trailing
                // guard in SwiftTerm's implicit link matcher.
                let range = trimmingTrailingPunctuation(match.range, in: nsText)
                guard range.length > 0 else { continue }
                if col >= range.location && col < range.location + range.length {
                    let url = nsText.substring(with: range)
                    return Detection(url: url, colStart: range.location, colEnd: range.location + range.length - 1)
                }
            }
        }

        if let regex = issueRefRegex {
            for match in regex.matches(in: text, range: fullRange) {
                let range = match.range
                if col >= range.location && col < range.location + range.length {
                    let ref = nsText.substring(with: range)
                    if let url = resolveIssueRef(ref, githubBaseURL: githubBaseURL) {
                        return Detection(url: url, colStart: range.location, colEnd: range.location + range.length - 1)
                    }
                }
            }
        }

        return nil
    }

    /// Strip trailing `.` and `,` (repeatedly) from a match range — they are
    /// sentence punctuation, not URL characters, when they end the match.
    static func trimmingTrailingPunctuation(_ range: NSRange, in nsText: NSString) -> NSRange {
        var range = range
        while range.length > 0 {
            let last = nsText.character(at: range.location + range.length - 1)
            if last == 0x2E /* . */ || last == 0x2C /* , */ {
                range.length -= 1
            } else {
                break
            }
        }
        return range
    }

    /// Resolve a GitHub issue reference to a URL.
    /// `"langwatch/langwatch#2847"` → `"https://github.com/langwatch/langwatch/pull/2847"`
    /// `"#123"` → uses `githubBaseURL` from the card's project
    static func resolveIssueRef(_ ref: String, githubBaseURL: String?) -> String? {
        guard let hashIndex = ref.firstIndex(of: "#") else { return nil }
        let numberStr = String(ref[ref.index(after: hashIndex)...])
        guard let number = Int(numberStr) else { return nil }

        let prefix = String(ref[ref.startIndex..<hashIndex])
        if prefix.isEmpty {
            guard let base = githubBaseURL else { return nil }
            return "\(base)/pull/\(number)"
        } else {
            return "https://github.com/\(prefix)/pull/\(number)"
        }
    }
}
