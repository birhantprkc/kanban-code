import Foundation
import Testing
@testable import KanbanCodeCore

struct SubagentCommandStoreTests {
    @Test("Command requests are claimed once and receive an atomic response")
    func claimAndRespond() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-subagent-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let request = SubagentCommandRequest(
            id: "request-1",
            operation: .spawn,
            createdAt: "2026-08-01T10:00:00.000Z",
            parentCardId: "parent-1",
            prompt: "Investigate",
            assistant: .codex,
            model: "gpt-5.4"
        )
        try JSONEncoder().encode(request).write(to: inbox.appendingPathComponent("request-1.json"))

        let store = SubagentCommandStore(baseURL: root)
        #expect(try await store.pendingRequestIds() == ["request-1"])
        #expect(try await store.claim(id: "request-1") == request)
        #expect(try await store.claim(id: "request-1") == nil)

        let response = SubagentCommandResponse(id: request.id, ok: true, cardId: "child-1")
        try await store.respond(response)
        let data = try Data(contentsOf: root.appendingPathComponent("responses/request-1.json"))
        #expect(try JSONDecoder().decode(SubagentCommandResponse.self, from: data) == response)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("processing/request-1.json").path))
    }
}
