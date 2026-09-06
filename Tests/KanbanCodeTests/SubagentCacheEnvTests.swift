import Testing

@testable import KanbanCode

@MainActor
@Suite("Subagent prompt cache tier")
struct SubagentCacheEnvTests {
    @Test("A claude subagent launches on the 5-minute prompt cache")
    func subagentGetsFiveMinuteCache() {
        #expect(
            ContentView.subagentCacheEnv(parentCardId: "card_parent", assistant: .claude)
                == ["CLAUDE_CODE_PROMPT_CACHE_TTL": "5m"])
    }

    @Test("A top-level card keeps the default cache")
    func topLevelCardKeepsDefault() {
        #expect(ContentView.subagentCacheEnv(parentCardId: nil, assistant: .claude) == nil)
    }

    @Test("Only claude reads the variable, other assistants get nothing")
    func otherAssistantsSkipIt() {
        #expect(ContentView.subagentCacheEnv(parentCardId: "card_parent", assistant: .codex) == nil)
    }
}
