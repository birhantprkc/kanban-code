import Testing
@testable import KanbanCodeCore

@Suite("Self-compact policy")
struct SelfCompactPolicyTests {
    @Test("Card threshold creates one nudge and forces compact 200k later")
    func cardThresholdRules() {
        let rules = SelfCompactPolicy.cardRules(thresholdTokens: 250_000)

        #expect(rules.map(\.thresholdTokens) == [250_000, 450_000])
        #expect(rules.map(\.action) == [.queuePrompt, .compactNow])
        #expect(rules[0].message.contains("250k context limit"))
        #expect(rules[0].message.contains("passing an argument for the post-compact message on how to continue"))
        #expect(rules[1].message == "/compact")
    }

    @Test("Card threshold replaces global rules while global guard is disabled")
    func cardThresholdOverridesDisabledGlobalGuard() {
        let global = SelfCompactSettings(enabled: false)

        #expect(
            SelfCompactPolicy.rules(cardThresholdTokens: 300_000, globalSettings: global)
                == SelfCompactPolicy.cardRules(thresholdTokens: 300_000)
        )
    }

    @Test("Missing card threshold follows global settings")
    func globalFallback() {
        let enabled = SelfCompactSettings(enabled: true)
        let disabled = SelfCompactSettings(enabled: false)

        #expect(SelfCompactPolicy.rules(cardThresholdTokens: nil, globalSettings: enabled) == SelfCompactRule.defaults)
        #expect(SelfCompactPolicy.rules(cardThresholdTokens: nil, globalSettings: disabled).isEmpty)
    }
}
