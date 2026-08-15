import KanbanCodeCore
import Testing

@testable import KanbanCode

/// Cmd+Shift+A archives the card you have open, after asking.
@Suite("Cmd+Shift+A archives the open card")
struct ArchiveShortcutTests {

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

    @Test("the shortcut is Cmd+Shift+A")
    func keyAndModifiers() {
        #expect(AppShortcut.archiveCard.key.character == "a")
        #expect(AppShortcut.archiveCard.modifiers == [.command, .shift])
        #expect(AppShortcut.archiveCard.displayString == "⇧⌘A")
    }

    @Test("nothing else answers to it")
    func noOtherShortcutTakesIt() {
        let sameKey = AppShortcut.allCases.filter {
            $0.key.character == "a" && $0.modifiers == [.command, .shift]
        }
        #expect(sameKey == [.archiveCard])
    }

    @Test("archiving needs a card to archive")
    func needsASelection() {
        #expect(AppShortcut.archiveCard.isActive(in: context(selectedCard: true)))
        #expect(!AppShortcut.archiveCard.isActive(in: context(selectedCard: false)))
    }

    /// The card you want to put away is usually the one you were typing into,
    /// so the prompt editor does not block it. The palette does, because it
    /// owns the keyboard and its own selection while it is up.
    @Test("it still works from the prompt editor, but not from the palette")
    func surfacesThatKeepIt() {
        #expect(AppShortcut.archiveCard.isActive(in: context(promptEditorFocused: true)))
        #expect(!AppShortcut.archiveCard.isActive(in: context(paletteOpen: true)))
    }

    @Test("the shortcut list still reports it")
    func listedInAllCases() {
        #expect(AppShortcut.allCases.contains(.archiveCard))
    }
}
