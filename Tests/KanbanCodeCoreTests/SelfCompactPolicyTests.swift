import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Self-compact policy")
struct SelfCompactPolicyTests {
    @Test("Card threshold escalates from nudge to steer to interrupt")
    func cardThresholdRules() {
        let rules = SelfCompactPolicy.cardRules(thresholdTokens: 250_000)

        #expect(rules.map(\.thresholdTokens) == [250_000, 350_000, 450_000])
        #expect(rules.map(\.action) == [.queuePrompt, .steer, .interrupt])
        #expect(rules[0].message.contains("250k context limit"))
        #expect(rules[0].message.contains("passing an argument for the post-compact message on how to continue"))
        #expect(rules[1].message.contains("350k context limit"))
        #expect(rules[2].message == "/compact")
    }

    @Test("Card rules escalate the same way the global defaults do")
    func cardRulesMirrorGlobalEscalation() {
        let card = SelfCompactPolicy.cardRules(thresholdTokens: 300_000).map(\.action)
        let global = SelfCompactRule.defaults.map(\.action)

        #expect(card == [.queuePrompt, .steer, .interrupt])
        #expect(Array(global.suffix(2)) == Array(card.suffix(2)))
    }

    @Test("Defaults steer before the last threshold interrupts")
    func defaultsEscalateToInterrupt() {
        let actions = SelfCompactRule.defaults.map(\.action)

        #expect(actions.last == .interrupt)
        #expect(actions.dropLast().last == .steer)
        #expect(actions.dropLast(2).allSatisfy { $0 == .queuePrompt })
    }

    @Test("A rule is dropped when the context is under its threshold again")
    func shouldSendChecksTheFreshContext() {
        let rule = SelfCompactPolicy.cardRules(thresholdTokens: 250_000)[1]

        #expect(SelfCompactPolicy.shouldSend(rule: rule, currentContextTokens: 360_000))
        #expect(SelfCompactPolicy.shouldSend(rule: rule, currentContextTokens: 350_000))
        #expect(!SelfCompactPolicy.shouldSend(rule: rule, currentContextTokens: 100_000))
    }

    @Test("An unknown context keeps the message")
    func shouldSendWithoutUsage() {
        let rule = SelfCompactPolicy.cardRules(thresholdTokens: 250_000)[1]

        #expect(SelfCompactPolicy.shouldSend(rule: rule, currentContextTokens: nil))
    }

    @Test("A warning wrapped in the composer box is found")
    func paneHasUnsentWrappedWarning() {
        let rules = SelfCompactPolicy.cardRules(thresholdTokens: 250_000)
        let messages = rules.map { SelfCompactPolicy.command(for: $0) }
        let pane = """
        > Compacting conversation...

        \u{276F} You are above the 350k context limit. Compact yourself now with the
        │ kanban CLI self-compact command, passing an argument for the post-compact
        │ message on how to continue.
        """

        #expect(SelfCompactPolicy.paneHasUnsentMessage(pane, messages: messages))
    }

    @Test("An empty composer and other text are left alone")
    func paneWithoutUnsentWarning() {
        let rules = SelfCompactPolicy.cardRules(thresholdTokens: 250_000)
        let messages = rules.map { SelfCompactPolicy.command(for: $0) }

        #expect(!SelfCompactPolicy.paneHasUnsentMessage("\u{276F} ", messages: messages))
        #expect(!SelfCompactPolicy.paneHasUnsentMessage("\u{276F} fix the failing test", messages: messages))
        #expect(!SelfCompactPolicy.paneHasUnsentMessage("no prompt line here", messages: messages))
    }

    @Test("Settings saved before the split decode compactNow as steer")
    func legacyActionDecodesAsSteer() throws {
        let legacy = Data(#"{"id":"ctx-750k","thresholdTokens":750000,"action":"compactNow","message":"/compact"}"#.utf8)

        let rule = try JSONDecoder().decode(SelfCompactRule.self, from: legacy)

        #expect(rule.action == .steer)
    }

    @Test("An empty steer or interrupt message still compacts")
    func emptyMessageFallsBackToCompact() {
        let blank = SelfCompactRule(id: "x", thresholdTokens: 1, action: .interrupt, message: "  \n ")
        let custom = SelfCompactRule(id: "y", thresholdTokens: 1, action: .steer, message: "wrap up")

        #expect(SelfCompactPolicy.command(for: blank) == "/compact")
        #expect(SelfCompactPolicy.command(for: custom) == "wrap up")
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
