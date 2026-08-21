import Foundation
import Testing

@testable import KanbanCodeCore

/// A session whose main agent is back at the prompt can still have subagents
/// working under it. Claude Code says so with SubagentStart and SubagentStop,
/// which carry the session that started them.
@Suite("Subagents working under a stopped session")
struct SubagentActivityTests {

    private func detector() -> ClaudeCodeActivityDetector {
        // No grace period, so a Stop is final the moment it lands.
        ClaudeCodeActivityDetector(stopDelay: 0)
    }

    @Test("a session that stopped with a subagent running is still working")
    func stopWithRunningSubagent() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "UserPromptSubmit"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))

        #expect(await detector.activityState(for: "s1") == .activelyWorking)
    }

    @Test("the session goes idle when its last subagent stops")
    func lastSubagentStopEndsTheWork() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
    }

    @Test("one of three subagents finishing leaves the session working")
    func remainingSubagentsKeepWorking() async {
        let detector = detector()

        for _ in 0..<3 {
            await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        }
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        #expect(await detector.activityState(for: "s1") == .activelyWorking)

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
    }

    /// The app reads the event file from where it stopped, so it can see a
    /// stop whose start it never read.
    @Test("a stop with no start of its own leaves the session idle")
    func unmatchedStopIsNotCountedBelowZero() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
    }

    @Test("subagent events belong to the session that started them")
    func subagentsAreCountedPerSession() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s2", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s2", eventName: "SubagentStart"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
        #expect(await detector.activityState(for: "s2") == .activelyWorking)
    }

    /// A session killed while its subagents work never sends their stops.
    @Test("a subagent that never stopped stops counting after its timeout")
    func abandonedSubagentExpires() async {
        let detector = ClaudeCodeActivityDetector(stopDelay: 0, subagentTimeout: 1)

        await detector.handleHookEvent(
            HookEvent(
                sessionId: "s1", eventName: "SubagentStart",
                timestamp: Date.now.addingTimeInterval(-60))
        )
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
    }

    @Test("a subagent still inside its timeout counts")
    func freshSubagentCounts() async {
        let detector = ClaudeCodeActivityDetector(stopDelay: 0, subagentTimeout: 3600)

        await detector.handleHookEvent(
            HookEvent(
                sessionId: "s1", eventName: "SubagentStart",
                timestamp: Date.now.addingTimeInterval(-60))
        )
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))

        #expect(await detector.activityState(for: "s1") == .activelyWorking)
    }

    @Test("a closed session is ended, whatever it had running")
    func sessionEndWins() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SessionEnd"))

        #expect(await detector.activityState(for: "s1") == .ended)
    }

    @Test("a resumed session starts counting again from nothing")
    func sessionStartClearsSubagents() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SessionStart"))

        #expect(await detector.activityState(for: "s1") == .idleWaiting)
    }

    /// Subagent events say what runs under the session, not what the session
    /// is doing, so they must not take the place of its own last event.
    @Test("a subagent event does not overwrite what the session last did")
    func subagentEventIsNotTheSessionsLastEvent() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "UserPromptSubmit"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        // Still mid-turn: the prompt is the last thing the session itself did.
        #expect(await detector.activityState(for: "s1") == .activelyWorking)
    }

    @Test("a session with subagents running lands in the in progress column")
    func workingSessionMovesToInProgress() async {
        var link = Link(id: "card_1", column: .waiting)

        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, hasWorktree: true)

        #expect(link.column == .inProgress)
    }

    @Test("the hooks the app installs cover subagents")
    func requiredHooksCoverSubagents() {
        let hooks = HookManager.requiredHooks(for: .claude)

        #expect(hooks.contains("SubagentStart"))
        #expect(hooks.contains("SubagentStop"))
    }
}
