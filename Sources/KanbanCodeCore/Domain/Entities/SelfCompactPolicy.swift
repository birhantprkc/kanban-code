import Foundation

/// How a threshold message reaches the agent. The three modes are the same
/// delivery semantics the CLI exposes through `kanban send --mode`.
public enum SelfCompactAction: String, Codable, Sendable, CaseIterable {
    case queuePrompt
    case steer
    case interrupt

    public var displayName: String {
        switch self {
        case .queuePrompt: "Queue prompt"
        case .steer: "Steer"
        case .interrupt: "Interrupt"
        }
    }

    public var detail: String {
        switch self {
        case .queuePrompt: "Waits in the card's queue and is sent once the agent goes idle."
        case .steer: "Pasted into the session right away. The agent reads it between turns."
        case .interrupt: "Stops the agent with Escape first, then sends the message."
        }
    }

    /// Settings saved before steering and interrupting were separate modes spell
    /// the steering action `compactNow`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "compactNow" {
            self = .steer
            return
        }
        guard let action = SelfCompactAction(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown self-compact action \"\(raw)\""
            )
        }
        self = action
    }
}

public struct SelfCompactRule: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var thresholdTokens: Int
    public var action: SelfCompactAction
    public var message: String

    public init(
        id: String,
        thresholdTokens: Int,
        action: SelfCompactAction,
        message: String
    ) {
        self.id = id
        self.thresholdTokens = thresholdTokens
        self.action = action
        self.message = message
    }

    public static let defaults: [SelfCompactRule] = [
        SelfCompactRule(
            id: "ctx-500k",
            thresholdTokens: 500_000,
            action: .queuePrompt,
            message: "You are above the 500k context limit. Whenever it is convenient, use the kanban CLI to send yourself a self-compact."
        ),
        SelfCompactRule(
            id: "ctx-600k",
            thresholdTokens: 600_000,
            action: .queuePrompt,
            message: "You are above the 600k context limit. Please compact yourself soon using the kanban CLI self-compact command."
        ),
        SelfCompactRule(
            id: "ctx-700k",
            thresholdTokens: 700_000,
            action: .steer,
            message: "You are above the 700k context limit. Compact yourself IMMEDIATELY using the kanban CLI self-compact command."
        ),
        SelfCompactRule(
            id: "ctx-750k",
            thresholdTokens: 750_000,
            action: .interrupt,
            message: "/compact"
        ),
    ]
}

public struct SelfCompactSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var pollIntervalSeconds: Int
    public var rules: [SelfCompactRule]

    public init(
        enabled: Bool = false,
        pollIntervalSeconds: Int = 30,
        rules: [SelfCompactRule] = SelfCompactRule.defaults
    ) {
        self.enabled = enabled
        self.pollIntervalSeconds = pollIntervalSeconds
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 30
        let decodedRules = (try? c.decodeIfPresent([SelfCompactRule].self, forKey: .rules)) ?? SelfCompactRule.defaults
        rules = decodedRules.isEmpty ? SelfCompactRule.defaults : decodedRules
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, pollIntervalSeconds, rules
    }
}

public enum SelfCompactPolicy {
    public static let steerOffsetTokens = 100_000
    public static let forcedCompactOffsetTokens = 200_000
    public static let cardThresholdOptions = Array(stride(from: 200_000, through: 750_000, by: 50_000))

    public static func rules(
        cardThresholdTokens: Int?,
        globalSettings: SelfCompactSettings
    ) -> [SelfCompactRule] {
        if let threshold = cardThresholdTokens, threshold > 0 {
            return cardRules(thresholdTokens: threshold)
        }
        guard globalSettings.enabled else { return [] }
        return globalSettings.rules
            .filter { $0.thresholdTokens > 0 }
            .sorted { $0.thresholdTokens < $1.thresholdTokens }
    }

    public static func cardRules(thresholdTokens: Int) -> [SelfCompactRule] {
        guard thresholdTokens > 0,
              thresholdTokens <= Int.max - forcedCompactOffsetTokens
        else { return [] }

        // Same escalation as the global defaults: ask while the agent can choose
        // its own moment, steer once it is overdue, interrupt when it is not
        // stopping on its own.
        let label = tokenLabel(thresholdTokens)
        let steerThreshold = thresholdTokens + steerOffsetTokens
        return [
            SelfCompactRule(
                id: "card-ctx-\(thresholdTokens)-nudge",
                thresholdTokens: thresholdTokens,
                action: .queuePrompt,
                message: "You are above the \(label) context limit. Whenever it is convenient, use the kanban CLI to send yourself a self-compact, passing an argument for the post-compact message on how to continue."
            ),
            SelfCompactRule(
                id: "card-ctx-\(steerThreshold)-steer",
                thresholdTokens: steerThreshold,
                action: .steer,
                message: "You are above the \(tokenLabel(steerThreshold)) context limit. Compact yourself now with the kanban CLI self-compact command, passing an argument for the post-compact message on how to continue."
            ),
            SelfCompactRule(
                id: "card-ctx-\(thresholdTokens + forcedCompactOffsetTokens)-force",
                thresholdTokens: thresholdTokens + forcedCompactOffsetTokens,
                action: .interrupt,
                message: "/compact"
            ),
        ]
    }

    /// An empty message on a steer or interrupt rule still has to say something,
    /// and the only useful thing to say at a context threshold is `/compact`.
    public static func command(for rule: SelfCompactRule) -> String {
        let trimmed = rule.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/compact" : rule.message
    }

    /// Whether a threshold message is still true. The context read that picked
    /// the rule can be a poll old, and a compact in between makes the message
    /// wrong, so the send path checks again with a fresh read. An unknown usage
    /// keeps the message, because the reason to send it has not been disproved.
    public static func shouldSend(rule: SelfCompactRule, currentContextTokens: Int?) -> Bool {
        guard let currentContextTokens else { return true }
        return currentContextTokens >= rule.thresholdTokens
    }

    /// Whether one of `messages` is waiting unsent in the composer of `pane`.
    /// The composer wraps the text inside a box, so both sides are compared
    /// without whitespace and box characters, and only by the start of the
    /// message.
    public static func paneHasUnsentMessage(_ pane: String, messages: [String]) -> Bool {
        guard let promptRange = pane.range(of: "\u{276F}", options: .backwards) else { return false }
        let composer = paneFingerprint(String(pane[promptRange.upperBound...]))
        guard !composer.isEmpty else { return false }
        for message in messages {
            let fingerprint = String(paneFingerprint(message).prefix(30))
            guard fingerprint.count >= 8 else { continue }
            if composer.contains(fingerprint) { return true }
        }
        return false
    }

    /// Lowercased text without whitespace and without the box characters the
    /// composer draws around it, so a wrapped line matches the original.
    static func paneFingerprint(_ text: String) -> String {
        let dropped = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\u{2502}\u{2500}\u{256D}\u{256E}\u{2570}\u{256F}\u{2503}|>")
        )
        return String(
            text.lowercased().unicodeScalars.filter { !dropped.contains($0) }.map(Character.init)
        )
    }

    public static func tokenLabel(_ tokens: Int) -> String {
        if tokens.isMultiple(of: 1_000) {
            return "\(tokens / 1_000)k"
        }
        return "\(tokens)"
    }

    public static func signature(for rules: [SelfCompactRule]) -> String {
        rules.map { "\($0.thresholdTokens):\($0.action.rawValue):\($0.message)" }.joined(separator: "|")
    }
}
