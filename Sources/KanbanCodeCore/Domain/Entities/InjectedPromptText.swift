import Foundation

/// Text an assistant CLI adds to the conversation as a user message before
/// the user types anything: Codex's `<environment_context>`,
/// `<recommended_plugins>` and `# AGENTS.md instructions`, Claude Code's
/// command wrappers. A card is never named after it.
public enum InjectedPromptText {
    private nonisolated(unsafe) static let leadingBlock = try! Regex(#"^\s*<([A-Za-z][A-Za-z0-9_\-]*)>[\s\S]*?</\1>"#)

    /// The text without the injected blocks it starts with; empty when the
    /// whole message was injected.
    public static func strip(_ text: String) -> String {
        var rest = Substring(text)
        if rest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# AGENTS.md instructions") { return "" }
        while let match = rest.prefixMatch(of: leadingBlock) {
            rest = rest[match.range.upperBound...]
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the whole message is injected text.
    public static func isInjected(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && strip(text).isEmpty
    }
}
