import AppKit
import Testing

@testable import KanbanCode

/// The dialogs keep their Cancel button on `.cancelAction`, but the key never
/// reaches it: the prompt and command text views are the first responder and
/// take Escape first, and the quit sheet has no close button to answer it.
/// Each of them therefore carries its own Escape handler.
@Suite("Escape dismisses the dialogs", .serialized)
@MainActor
struct EscapeDismissTests {

    private func escapeEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!
    }

    @Test("the prompt editor hands Escape to the dialog")
    func promptEditorEscape() {
        var cancelled = false
        let textView = SubmitTextView()
        textView.onEscape = { cancelled = true }
        textView.keyDown(with: escapeEvent())
        #expect(cancelled)
    }

    @Test("the command editor hands Escape to the dialog")
    func commandEditorEscape() {
        var cancelled = false
        let textView = CommandNSTextView()
        textView.onEscape = { cancelled = true }
        textView.keyDown(with: escapeEvent())
        #expect(cancelled)
    }

    @Test("the command editor keeps Return for the submit button")
    func commandEditorReturn() {
        var cancelled = false
        var submitted = false
        let textView = CommandNSTextView()
        textView.onEscape = { cancelled = true }
        textView.onSubmit = { submitted = true }
        let returnEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!
        textView.keyDown(with: returnEvent)
        #expect(submitted)
        #expect(!cancelled)
    }

    @Test("the quit sheet answers Escape as a cancel")
    func quitPanelEscape() {
        var cancelled = 0
        let panel = EscapeCancellingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.onCancel = { cancelled += 1 }
        panel.keyDown(with: escapeEvent())
        #expect(cancelled == 1)
        panel.cancelOperation(nil)
        #expect(cancelled == 2)
    }
}
