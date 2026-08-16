import KanbanCodeCore
import Testing

@testable import KanbanCode

/// Cmd+R renames the card you have open, and still reloads a browser tab when
/// one is showing.
@Suite("Cmd+R renames the open card")
struct RenameShortcutTests {

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

    @Test("the shortcut is Cmd+R")
    func keyAndModifiers() {
        #expect(AppShortcut.renameCard.key.character == "r")
        #expect(AppShortcut.renameCard.modifiers == .command)
        #expect(AppShortcut.renameCard.displayString == "⌘R")
    }

    /// Both are told, and the surface on screen answers: the browser reloads
    /// only while one of its tabs is selected, the rename opens only while
    /// none is. Anything else on Cmd+R would make that arrangement wrong.
    @Test("Cmd+R belongs to the rename and the browser reload, and to nothing else")
    func sharedWithTheBrowserReloadOnly() {
        let owners = AppShortcut.allCases.filter {
            $0.key.character == "r" && $0.modifiers == .command
        }
        #expect(Set(owners.map(\.self.displayString)) == ["⌘R"])
        #expect(owners.count == 2)
        #expect(owners.contains(.renameCard))
        #expect(owners.contains(.browserReload))
    }

    @Test("renaming needs a card to rename")
    func needsASelection() {
        #expect(AppShortcut.renameCard.isActive(in: context(selectedCard: true)))
        #expect(!AppShortcut.renameCard.isActive(in: context(selectedCard: false)))
    }

    @Test("it still works from the prompt editor, but not from the palette")
    func surfacesThatKeepIt() {
        #expect(AppShortcut.renameCard.isActive(in: context(promptEditorFocused: true)))
        #expect(!AppShortcut.renameCard.isActive(in: context(paletteOpen: true)))
    }

    @Test("the shortcut list still reports it")
    func listedInAllCases() {
        #expect(AppShortcut.allCases.contains(.renameCard))
    }
}
