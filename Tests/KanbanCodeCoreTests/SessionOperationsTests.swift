import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Session Operations")
struct SessionOperationsTests {
    let store = ClaudeCodeSessionStore()

    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-ops-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Fork creates new file with new session ID")
    func fork() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("original-id.jsonl")
        try [
            #"{"type":"user","sessionId":"original-id","message":{"content":"Hello"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"original-id","message":{"content":[{"type":"text","text":"Hi"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let newId = try await store.forkSession(sessionPath: path)
        #expect(!newId.isEmpty)
        #expect(newId != "original-id")

        // Check new file exists
        let newPath = (dir as NSString).appendingPathComponent("\(newId).jsonl")
        #expect(FileManager.default.fileExists(atPath: newPath))

        // Check session IDs were replaced
        let content = try String(contentsOfFile: newPath, encoding: .utf8)
        #expect(content.contains(newId))
        #expect(!content.contains("original-id"))
    }

    @Test("Checkpoint truncates after given turn")
    func checkpoint() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("sess.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"First"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Reply 1"}]}}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Second"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Reply 2"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        // lineNumber is a byte offset — line 2 starts at byte 77 (76 chars + newline)
        let turn = ConversationTurn(index: 1, lineNumber: 77, role: "assistant", textPreview: "Reply 1")
        try await store.truncateSession(sessionPath: path, afterTurn: turn)

        // Check backup was created
        #expect(FileManager.default.fileExists(atPath: path + ".bkp"))

        // Check truncated file has only 2 lines
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(content.contains("First"))
        #expect(content.contains("Reply 1"))
        #expect(!content.contains("Second"))
    }

    @Test("Checkpoint keeps every record of a turn stitched from several")
    func checkpointMergedTurn() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // The way Claude Code writes a reply: thinking on one line, the text
        // on the next. The chat shows them as one bubble.
        let path = (dir as NSString).appendingPathComponent("sess.jsonl")
        try [
            #"{"type":"user","sessionId":"s1","message":{"content":"First"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"thinking","thinking":"hm"}]}}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Reply 1"}]}}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Second"},"cwd":"/test"}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await TranscriptReader.readTail(from: path, maxTurns: 10)
        let reply = result.turns.first { $0.role == "assistant" }
        #expect(reply != nil)
        #expect((reply?.endLineNumber ?? 0) > (reply?.lineNumber ?? 0))

        try await store.truncateSession(sessionPath: path, afterTurn: reply!)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("Reply 1"))
        #expect(!content.contains("Second"))
    }

    @Test("Checkpoint backup preserves original")
    func checkpointBackup() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("sess.jsonl")
        let originalContent = [
            #"{"type":"user","sessionId":"s1","message":{"content":"Line 1"},"cwd":"/test"}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"Line 2"},"cwd":"/test"}"#,
        ].joined(separator: "\n")
        try originalContent.write(toFile: path, atomically: true, encoding: .utf8)

        let turn = ConversationTurn(index: 0, lineNumber: 1, role: "user", textPreview: "Line 1")
        try await store.truncateSession(sessionPath: path, afterTurn: turn)

        let backup = try String(contentsOfFile: path + ".bkp", encoding: .utf8)
        #expect(backup.contains("Line 1"))
        #expect(backup.contains("Line 2"))
    }

    @Test("Fork nonexistent file throws")
    func forkNonexistent() async throws {
        await #expect(throws: SessionStoreError.self) {
            try await store.forkSession(sessionPath: "/nonexistent.jsonl")
        }
    }

    @Test("Search finds matching sessions")
    func search() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path1 = (dir as NSString).appendingPathComponent("s1.jsonl")
        try #"{"type":"user","sessionId":"s1","message":{"content":"Fix the authentication bug in login"},"cwd":"/test"}"#
            .write(toFile: path1, atomically: true, encoding: .utf8)

        let path2 = (dir as NSString).appendingPathComponent("s2.jsonl")
        try #"{"type":"user","sessionId":"s2","message":{"content":"Add new dashboard feature"},"cwd":"/test"}"#
            .write(toFile: path2, atomically: true, encoding: .utf8)

        let results = try await store.searchSessions(query: "authentication login", paths: [path1, path2])
        #expect(!results.isEmpty)
        #expect(results[0].sessionPath == path1) // auth/login session should rank first
        #expect(results[0].score > 0)
    }

    @Test("Search returns empty for no matches")
    func searchNoMatch() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("s1.jsonl")
        try #"{"type":"user","sessionId":"s1","message":{"content":"Hello world"},"cwd":"/test"}"#
            .write(toFile: path, atomically: true, encoding: .utf8)

        let results = try await store.searchSessions(query: "zzzznotfound", paths: [path])
        #expect(results.isEmpty)
    }
}
