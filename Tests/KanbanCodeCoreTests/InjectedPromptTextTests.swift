import Testing
@testable import KanbanCodeCore

@Suite struct InjectedPromptTextTests {
    @Test func dropsCodexPluginListAndKeepsWhatFollows() {
        let text = "<recommended_plugins>\nHere is a list of plugins that are available.\n</recommended_plugins>\n\nFix the login bug"
        #expect(InjectedPromptText.strip(text) == "Fix the login bug")
    }

    @Test func aMessageOfOnlyInjectedBlocksIsInjected() {
        #expect(InjectedPromptText.isInjected("<environment_context>\n<cwd>/x</cwd>\n</environment_context>"))
        #expect(InjectedPromptText.isInjected("# AGENTS.md instructions for /x\n\n<INSTRUCTIONS>be nice</INSTRUCTIONS>"))
        #expect(!InjectedPromptText.isInjected("Use <b>bold</b> in the title"))
    }

    @Test func aTagInsideThePromptStays() {
        #expect(InjectedPromptText.strip("Rename <Button> to <Link>") == "Rename <Button> to <Link>")
    }

    @Test func cardTitleSkipsTheInjectedBlock() {
        let link = Link(promptBody: "<recommended_plugins>\nplugins\n</recommended_plugins>\nShip the release notes")
        #expect(link.displayTitle == "Ship the release notes")
    }
}
