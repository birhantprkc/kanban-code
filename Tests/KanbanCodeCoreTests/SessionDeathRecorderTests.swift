import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Session death recorder")
struct SessionDeathRecorderTests {
    @Test("The snapshot survives on disk and forgets killed sessions")
    func snapshotRoundTrip() {
        let home = NSTemporaryDirectory() + "death-snapshot-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }

        #expect(SessionDeathRecorder.readSnapshot(kanbanHome: home) == nil)

        SessionDeathRecorder.writeSnapshot(["claude-a", "claude-b", "repo-card_1"], kanbanHome: home)
        #expect(SessionDeathRecorder.readSnapshot(kanbanHome: home) == ["claude-a", "claude-b", "repo-card_1"])

        SessionDeathRecorder.removeFromSnapshot(["claude-b"], kanbanHome: home)
        #expect(SessionDeathRecorder.readSnapshot(kanbanHome: home) == ["claude-a", "repo-card_1"])
    }

    @Test("Test-suite sessions never count as deaths")
    func expectedDeaths() {
        #expect(SessionDeathRecorder.isExpectedDeath("kanban-e2e-alice-1788503534236"))
        #expect(!SessionDeathRecorder.isExpectedDeath("claude-9262728b"))
    }
}
