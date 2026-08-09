import KanbanCodeCore
import Testing

@testable import KanbanCode

/// Cmd+P used to be a second way to open the quick palette, which Cmd+K already
/// does. It now pins and unpins the selected card.
@Suite("Cmd+P pins the selected card")
struct TogglePinShortcutTests {

    private func context(
        selectedCard: Bool = true,
        paletteOpen: Bool = false,
        promptEditorFocused: Bool = false
    ) -> AppShortcutContext {
        AppShortcutContext(
            paletteOpen: paletteOpen,
            detailOpen: selectedCard,
            expandedDetail: false,
            promptEditorFocused: promptEditorFocused,
            hasSelectedCard: selectedCard
        )
    }

    @Test("Cmd+P is the pin toggle")
    func keyAndModifiers() {
        #expect(AppShortcut.togglePin.key.character == "p")
        #expect(AppShortcut.togglePin.modifiers == .command)
        #expect(AppShortcut.togglePin.displayString == "⌘P")
    }

    @Test("the palette is on Cmd+K alone")
    func paletteNoLongerOnP() {
        let paletteKeys = AppShortcut.allCases
            .filter { $0.modifiers == .command && $0.key.character == "p" }
        #expect(paletteKeys == [.togglePin])
    }

    @Test("Cmd+Shift+P still opens command mode")
    func commandModeUnchanged() {
        #expect(AppShortcut.openCommandMode.key.character == "p")
        #expect(AppShortcut.openCommandMode.modifiers == [.command, .shift])
    }

    @Test("pinning needs a card to pin")
    func needsASelection() {
        #expect(AppShortcut.togglePin.isActive(in: context(selectedCard: true)))
        #expect(!AppShortcut.togglePin.isActive(in: context(selectedCard: false)))
    }

    /// The palette owns the keyboard while it is up, and a prompt editor needs
    /// its own Cmd+P.
    @Test("pinning stays out of the way of the palette and the prompt editor")
    func yieldsToOtherSurfaces() {
        #expect(!AppShortcut.togglePin.isActive(in: context(paletteOpen: true)))
        #expect(!AppShortcut.togglePin.isActive(in: context(promptEditorFocused: true)))
    }
}
