import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Queued prompt journal")
struct QueuedPromptJournalTests {

    private static func scratch() -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("queued-prompt-journal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private static func entry(
        cardId: String = "card_1",
        promptId: String = "prompt_1",
        reason: QueuedPromptJournalReason = .queued,
        body: String = "do the thing"
    ) -> QueuedPromptJournalEntry {
        QueuedPromptJournalEntry(
            cardId: cardId, promptId: promptId, reason: reason, body: body,
            imagePaths: nil, sendAutomatically: true
        )
    }

    @Test("a prompt survives being written and read back")
    func roundTrip() async {
        let journal = QueuedPromptJournal(basePath: Self.scratch())
        let body = String(repeating: "a long prompt body that someone typed once. ", count: 400)
        await journal.append(Self.entry(body: body))

        let entries = await journal.entries(forCard: "card_1")
        #expect(entries.count == 1)
        #expect(entries.first?.body == body)
        #expect(entries.first?.reason == .queued)
    }

    @Test("a prompt keeps its whole life, in order")
    func recordsEveryStage() async {
        let journal = QueuedPromptJournal(basePath: Self.scratch())
        await journal.append(Self.entry(reason: .queued, body: "first draft"))
        await journal.append(Self.entry(reason: .edited, body: "second draft"))
        await journal.append(Self.entry(reason: .sent, body: "second draft"))

        let entries = await journal.entries(forCard: "card_1")
        #expect(entries.map(\.reason) == [.queued, .edited, .sent])
        #expect(entries.map(\.body) == ["first draft", "second draft", "second draft"])
    }

    @Test("other cards stay out of the way")
    func filtersByCard() async {
        let journal = QueuedPromptJournal(basePath: Self.scratch())
        await journal.append(Self.entry(cardId: "card_1", body: "mine"))
        await journal.append(Self.entry(cardId: "card_2", body: "theirs"))

        #expect(await journal.entries(forCard: "card_1").map(\.body) == ["mine"])
        #expect(await journal.allEntries().count == 2)
    }

    /// A recovery file that grows without end is its own kind of problem.
    @Test("the journal drops its oldest half once it passes its limit")
    func trimsWhenTooBig() async {
        let base = Self.scratch()
        let journal = QueuedPromptJournal(basePath: base, sizeLimit: 4_000)
        for i in 0..<40 {
            await journal.append(Self.entry(promptId: "prompt_\(i)", body: String(repeating: "x", count: 200)))
        }

        let entries = await journal.allEntries()
        #expect(entries.count < 40)
        #expect(!entries.isEmpty)
        // What survives is the recent end, which is what anyone would go back for.
        #expect(entries.last?.promptId == "prompt_39")

        let size = (try? FileManager.default.attributesOfItem(atPath:
            (base as NSString).appendingPathComponent("queued-prompts.jsonl")))?[.size] as? NSNumber
        #expect((size?.intValue ?? 0) <= 8_000)
    }

    @Test("a missing journal reads as empty rather than failing")
    func missingFile() async {
        let journal = QueuedPromptJournal(basePath: Self.scratch())
        #expect(await journal.allEntries().isEmpty)
    }
}
