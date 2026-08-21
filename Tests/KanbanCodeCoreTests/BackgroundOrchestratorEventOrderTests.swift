import Foundation
import Testing

@testable import KanbanCodeCore

private struct EmptyDiscovery: SessionDiscovery {
    func discoverSessions() async throws -> [Session] { [] }
    func discoverNewOrModified(since: Date) async throws -> [Session] { [] }
}

/// Records every event it is handed, with a suspension inside so overlapping
/// passes would interleave if the orchestrator let them.
private actor RecordingDetector: ActivityDetector {
    private var received: [String] = []

    func handleHookEvent(_ event: HookEvent) async {
        try? await Task.sleep(for: .milliseconds(1))
        received.append(event.sessionId)
    }

    func pollActivity(sessionPaths: [String: String]) async -> [String: ActivityState] { [:] }
    func activityState(for sessionId: String) async -> ActivityState { .stale }

    func events() -> [String] { received }
}

/// processHookEvents is called from the main actor (file watcher) and from
/// the background tick, and suspends at every await. Unserialized, two calls
/// interleave: both take the initial-load branch, and a fresh event read by
/// the second call lands in the detector before the first call's replay is
/// done — an old event then overwrites a newer one for the same session.
@Suite("Hook event passes feed the detector in file order")
struct BackgroundOrchestratorEventOrderTests {

    @Test("a pass racing the initial load queues behind it")
    func concurrentPassesStaySerialized() async throws {
        let dir = NSTemporaryDirectory() + "kanban-orchestrator-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let eventsPath = (dir as NSString).appendingPathComponent("hook-events.jsonl")
        let backlog = (0..<30).map {
            #"{"sessionId":"old-\#($0)","event":"UserPromptSubmit","timestamp":"2026-08-21T10:00:00Z"}"#
        }
        try backlog.joined(separator: "\n").write(
            toFile: eventsPath, atomically: true, encoding: .utf8)

        let detector = RecordingDetector()
        let orchestrator = BackgroundOrchestrator(
            discovery: EmptyDiscovery(),
            coordinationStore: CoordinationStore(basePath: dir),
            activityDetector: detector,
            hookEventStore: HookEventStore(basePath: dir)
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await orchestrator.processHookEvents() }
            group.addTask {
                // Land mid-replay: the backlog takes ~30ms to feed.
                try? await Task.sleep(for: .milliseconds(5))
                let line =
                    #"{"sessionId":"fresh","event":"UserPromptSubmit","timestamp":"2026-08-21T10:00:01Z"}"#
                if let handle = FileHandle(forWritingAtPath: eventsPath) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(("\n" + line).utf8))
                    try? handle.close()
                }
                await orchestrator.processHookEvents()
            }
        }

        let received = await detector.events()
        #expect(received.count == 31)
        #expect(received.suffix(1) == ["fresh"])
        #expect(Array(received.prefix(30)) == (0..<30).map { "old-\($0)" })
    }
}
