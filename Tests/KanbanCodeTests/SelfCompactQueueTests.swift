import Testing
@testable import KanbanCode
import KanbanCodeCore

@Suite("Self-compact queue")
struct SelfCompactQueueTests {
    @Test("Higher threshold removes older compact nudge but keeps user prompts and higher nudges")
    func higherThresholdRemovesOnlyOlderCompactNudges() {
        let prompts = [
            QueuedPrompt(id: "prompt_user_before", body: "user queued work"),
            QueuedPrompt(
                id: "prompt_500",
                body: "500k nudge",
                selfCompactThresholdTokens: 500_000
            ),
            QueuedPrompt(
                id: "prompt_700",
                body: "700k nudge",
                selfCompactThresholdTokens: 700_000
            ),
            QueuedPrompt(id: "prompt_user_after", body: "another user prompt"),
        ]

        let ids = ContentView.queuedSelfCompactWarningIdsToRemove(
            prompts: prompts,
            warningBodies: ["500k nudge", "600k nudge", "700k nudge"],
            throughThreshold: 600_000
        )

        #expect(ids == ["prompt_500"])
    }

    @Test("Legacy compact nudges can still be removed by configured body")
    func legacyCompactNudgesRemoveByBody() {
        let prompts = [
            QueuedPrompt(id: "prompt_user", body: "user queued work"),
            QueuedPrompt(id: "prompt_legacy", body: "500k nudge", sendAutomatically: true),
        ]

        let ids = ContentView.queuedSelfCompactWarningIdsToRemove(
            prompts: prompts,
            warningBodies: ["500k nudge"],
            throughThreshold: 600_000
        )

        #expect(ids == ["prompt_legacy"])
    }
}
