import Foundation

/// A stretch of transcript the chat keeps on disk instead of in memory.
///
/// The bytes between `startOffset` and `endOffset` hold no message the user
/// typed, only the assistant working. The chat draws the stretch as one line
/// with a count, and parses the bytes only when the reader asks to see them.
public struct CollapsedTurnRange: Sendable, Equatable, Identifiable {
    /// Byte offset of the first hidden line.
    public let startOffset: Int
    /// Byte offset of the first line after the stretch (exclusive).
    public let endOffset: Int
    /// How many rows the stretch draws when expanded.
    public let messageCount: Int

    public var id: Int { startOffset }

    public init(startOffset: Int, endOffset: Int, messageCount: Int) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.messageCount = messageCount
    }
}

/// Pure bookkeeping for a chat window that is a sparse view of one file:
/// a fully loaded tail, islands of user messages above it, and collapsed
/// ranges covering the bytes in between.
public enum TranscriptWindow {

    /// Replace the tail of the window with a fresh parse of the same bytes.
    ///
    /// `start` is the byte offset the re-parse began at, which is the start
    /// of the last loaded turn: the last turn is parsed again because lines
    /// appended since may belong to it, and a partial response becomes a full
    /// one. The re-parsed turn takes over the index of the turn it replaces,
    /// so a splice that changes nothing produces the very same values and no
    /// row is rebuilt for it.
    public static func splice(
        turns: [ConversationTurn], reparsedFrom start: Int, with reparsed: [ConversationTurn]
    ) -> [ConversationTurn] {
        let base = turns.first { $0.lineNumber == start }.map(\.index)
        var kept = turns.filter { $0.lineNumber < start }
        kept.append(contentsOf: reindex(reparsed, from: base ?? (kept.last?.index ?? -1) + 1))
        return kept
    }

    /// Add loaded turns to the window, keeping file order.
    ///
    /// A turn already loaded stays as it is: the window's copy was parsed
    /// with its neighbours and carries the fresher content.
    public static func merge(
        turns: [ConversationTurn], inserting newTurns: [ConversationTurn]
    ) -> [ConversationTurn] {
        var byOffset: [Int: ConversationTurn] = [:]
        for turn in turns { byOffset[turn.lineNumber] = turn }
        for turn in newTurns where byOffset[turn.lineNumber] == nil {
            byOffset[turn.lineNumber] = turn
        }
        return byOffset.values.sorted { $0.lineNumber < $1.lineNumber }
    }

    /// Take a parsed byte region out of the collapsed ranges.
    ///
    /// A range the region cuts through comes back in `toRecount` with a zero
    /// count, because only a scan of its bytes can say how many rows each
    /// side still hides. The caller counts them and folds them back in.
    public static func subtract(
        region: Range<Int>, from ranges: [CollapsedTurnRange]
    ) -> (kept: [CollapsedTurnRange], toRecount: [CollapsedTurnRange]) {
        var kept: [CollapsedTurnRange] = []
        var toRecount: [CollapsedTurnRange] = []
        for range in ranges {
            if range.endOffset <= region.lowerBound || range.startOffset >= region.upperBound {
                kept.append(range)
                continue
            }
            if range.startOffset < region.lowerBound {
                toRecount.append(
                    CollapsedTurnRange(
                        startOffset: range.startOffset, endOffset: region.lowerBound,
                        messageCount: 0))
            }
            if region.upperBound < range.endOffset {
                toRecount.append(
                    CollapsedTurnRange(
                        startOffset: region.upperBound, endOffset: range.endOffset,
                        messageCount: 0))
            }
        }
        return (kept, toRecount)
    }

    private static func reindex(_ turns: [ConversationTurn], from base: Int) -> [ConversationTurn] {
        turns.enumerated().map { position, turn in
            ConversationTurn(
                index: base + position,
                lineNumber: turn.lineNumber,
                role: turn.role,
                textPreview: turn.textPreview,
                timestamp: turn.timestamp,
                contentBlocks: turn.contentBlocks,
                imageCount: turn.imageCount,
                modelName: turn.modelName
            )
        }
    }
}

/// Tells the messages a person typed apart from everything else the user side
/// of a transcript carries: tool results, agents reporting in, interruption
/// notes, slash command wrappers, and the reminders the harness injects.
public enum TranscriptClassifier {

    /// Whether a turn is something the person typed.
    public static func isTypedMessage(_ turn: ConversationTurn) -> Bool {
        guard turn.role == "user" else { return false }
        return turn.contentBlocks.contains { block in
            guard case .text = block.kind else { return false }
            return self.isTypedText(block.text)
        }
    }

    public static func isTypedText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // An agent reporting in, drawn as a system line rather than a message.
        if trimmed.hasPrefix("✓ ") || trimmed.hasPrefix("⏳ ") { return false }
        if trimmed.contains("[Request interrupted by user") { return false }
        if trimmed.hasPrefix("Caveat: The messages below were generated by the user") {
            return false
        }
        // What is left after the harness's own tags come out. A message that is
        // only tags was written by the tooling, not by the person.
        let remaining = JsonlParser.stripMetadataTags(trimmed)
            .replacing(Self.systemReminderRegex, with: "")
        return !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private nonisolated(unsafe) static let systemReminderRegex =
        try! Regex("<system-reminder>[\\s\\S]*?</system-reminder>")
}

extension ConversationTurn {
    /// Whether the chat draws a row for this turn.
    ///
    /// Tool results never draw their own row: they appear inside the card of
    /// the call that produced them.
    public var hasVisibleChatContent: Bool {
        if self.role == "user" {
            return self.contentBlocks.contains { block in
                guard case .text = block.kind else { return false }
                return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return self.contentBlocks.contains { block in
            switch block.kind {
            case .text:
                return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .toolUse, .agentCall, .planModeExit, .askUserQuestion, .planModeEnter:
                return true
            case .toolResult:
                return false
            case .thinking:
                return !block.text.isEmpty
            }
        }
    }
}
