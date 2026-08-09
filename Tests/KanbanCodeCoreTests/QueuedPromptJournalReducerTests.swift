import Foundation
import Testing

@testable import KanbanCodeCore

/// Sending a queued prompt deletes it from the card and persists that deletion
/// alongside the send, so a send that fails or only partly lands takes the text
/// with it and nothing retries. Every way a prompt can leave the queue has to
/// write it down first.
@Suite("Reducer — queued prompt journal")
struct QueuedPromptJournalReducerTests {

    private func stateWithQueued(_ prompts: [QueuedPrompt]) -> AppState {
        let state = AppState()
        var link = Link(id: "card_1", name: "a card", projectPath: "/tmp/project")
        link.tmuxLink = TmuxLink(sessionName: "claude-abc")
        link.queuedPrompts = prompts
        state.links[link.id] = link
        return state
    }

    private func journalled(_ effects: [Effect]) -> [(QueuedPrompt, QueuedPromptJournalReason)] {
        effects.compactMap {
            if case .journalQueuedPrompt(_, let prompt, let reason) = $0 { return (prompt, reason) }
            return nil
        }
    }

    @Test("sending writes the body down before handing it to tmux")
    func sendJournalsFirst() {
        let prompt = QueuedPrompt(id: "prompt_1", body: "a long thing I typed once")
        var state = stateWithQueued([prompt])

        let effects = Reducer.reduce(
            state: &state, action: .sendQueuedPrompt(cardId: "card_1", promptId: "prompt_1"))

        let entries = journalled(effects)
        #expect(entries.count == 1)
        #expect(entries.first?.0.body == "a long thing I typed once")
        #expect(entries.first?.1 == .sent)

        // Before the send, because the send is what loses it.
        let journalIndex = effects.firstIndex { if case .journalQueuedPrompt = $0 { return true }; return false }
        let sendIndex = effects.firstIndex { if case .sendPromptToTmux = $0 { return true }; return false }
        #expect(journalIndex != nil)
        #expect(sendIndex != nil)
        if let journalIndex, let sendIndex { #expect(journalIndex < sendIndex) }

        // And it really is gone from the card at that point.
        #expect(state.links["card_1"]?.queuedPrompts == nil)
    }

    @Test("queueing writes the body down")
    func addJournals() {
        var state = stateWithQueued([])
        let prompt = QueuedPrompt(id: "prompt_1", body: "draft one")

        let effects = Reducer.reduce(
            state: &state, action: .addQueuedPrompt(cardId: "card_1", prompt: prompt, placement: .back))

        #expect(journalled(effects).map(\.1) == [.queued])
        #expect(journalled(effects).first?.0.body == "draft one")
    }

    @Test("editing writes the new body down, not the old one")
    func updateJournalsTheNewBody() {
        var state = stateWithQueued([QueuedPrompt(id: "prompt_1", body: "draft one")])

        let effects = Reducer.reduce(
            state: &state,
            action: .updateQueuedPrompt(
                cardId: "card_1", promptId: "prompt_1", body: "draft two",
                sendAutomatically: false)
        )

        #expect(journalled(effects).map(\.1) == [.edited])
        #expect(journalled(effects).first?.0.body == "draft two")
    }

    @Test("deleting writes the body down too")
    func removeJournals() {
        var state = stateWithQueued([QueuedPrompt(id: "prompt_1", body: "never mind")])

        let effects = Reducer.reduce(
            state: &state, action: .removeQueuedPrompt(cardId: "card_1", promptId: "prompt_1"))

        #expect(journalled(effects).map(\.1) == [.removed])
        #expect(journalled(effects).first?.0.body == "never mind")
    }

    @Test("deleting something that is not there writes nothing")
    func removeMissingJournalsNothing() {
        var state = stateWithQueued([QueuedPrompt(id: "prompt_1", body: "here")])

        let effects = Reducer.reduce(
            state: &state, action: .removeQueuedPrompt(cardId: "card_1", promptId: "prompt_missing"))

        #expect(journalled(effects).isEmpty)
    }

    @Test("images travel with the record")
    func keepsImagePaths() {
        let prompt = QueuedPrompt(
            id: "prompt_1", body: "look at this", imagePaths: ["/tmp/a.png", "/tmp/b.png"])
        var state = stateWithQueued([prompt])

        let effects = Reducer.reduce(
            state: &state, action: .sendQueuedPrompt(cardId: "card_1", promptId: "prompt_1"))

        #expect(journalled(effects).first?.0.imagePaths == ["/tmp/a.png", "/tmp/b.png"])
    }
}
