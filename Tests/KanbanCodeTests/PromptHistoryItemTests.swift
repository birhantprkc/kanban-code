import Foundation
import KanbanCodeCore
import Testing

@testable import KanbanCode

@Suite("Prompt history")
struct PromptHistoryItemTests {

    private static func entry(
        _ promptId: String,
        _ reason: QueuedPromptJournalReason,
        _ body: String,
        secondsAgo: TimeInterval,
        imagePaths: [String]? = nil
    ) -> QueuedPromptJournalEntry {
        QueuedPromptJournalEntry(
            timestamp: Date(timeIntervalSince1970: 1_000_000 - secondsAgo),
            cardId: "card_1",
            promptId: promptId,
            reason: reason,
            body: body,
            imagePaths: imagePaths,
            sendAutomatically: true
        )
    }

    /// A prompt is written down at every step, so the composer alone leaves two
    /// records of one message. The history is a list of prompts, not of events.
    @Test("one row per prompt, showing its latest state")
    func collapsesToLatest() {
        let items = PromptHistoryItem.from([
            Self.entry("p1", .queued, "draft", secondsAgo: 30),
            Self.entry("p1", .sent, "draft", secondsAgo: 29),
        ])

        #expect(items.count == 1)
        #expect(items.first?.reason == .sent)
        #expect(items.first?.status == "Sent")
    }

    @Test("an edited prompt shows the text it ended up with")
    func keepsTheLastEdit() {
        let items = PromptHistoryItem.from([
            Self.entry("p1", .queued, "first try", secondsAgo: 60),
            Self.entry("p1", .edited, "second try", secondsAgo: 40),
            Self.entry("p1", .edited, "third try", secondsAgo: 20),
        ])

        #expect(items.map(\.body) == ["third try"])
    }

    @Test("newest first, whatever order the journal was read in")
    func sortsNewestFirst() {
        let items = PromptHistoryItem.from([
            Self.entry("p1", .sent, "oldest", secondsAgo: 300),
            Self.entry("p3", .sent, "newest", secondsAgo: 10),
            Self.entry("p2", .sent, "middle", secondsAgo: 100),
        ])

        #expect(items.map(\.body) == ["newest", "middle", "oldest"])
    }

    /// A deleted prompt is exactly the one worth getting back.
    @Test("a deleted prompt stays in the history")
    func keepsDeleted() {
        let items = PromptHistoryItem.from([
            Self.entry("p1", .queued, "never mind", secondsAgo: 60),
            Self.entry("p1", .removed, "never mind", secondsAgo: 30),
        ])

        #expect(items.map(\.status) == ["Deleted"])
        #expect(items.map(\.body) == ["never mind"])
    }

    @Test("empty prompts are not worth a row")
    func dropsEmpty() {
        let items = PromptHistoryItem.from([
            Self.entry("p1", .sent, "   \n ", secondsAgo: 30),
            Self.entry("p2", .sent, "real one", secondsAgo: 20),
        ])

        #expect(items.map(\.body) == ["real one"])
    }

    @Test("attachments are counted")
    func countsImages() {
        let items = PromptHistoryItem.from([
            Self.entry("p1", .sent, "look", secondsAgo: 10, imagePaths: ["/a.png", "/b.png"])
        ])

        #expect(items.first?.imageCount == 2)
    }
}
