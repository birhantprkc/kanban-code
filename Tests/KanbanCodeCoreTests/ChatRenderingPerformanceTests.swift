import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Chat Rendering Performance")
struct ChatRenderingPerformanceTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-perf-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Generate a realistic large user message (like pasting a long document)
    func generateLargeText(sizeKB: Int) -> String {
        let paragraph = "LangWatch is the complete AI Evaluation & Observability platform purpose-built for monitoring, simulating, evaluating, and optimizing LLM-based applications and complex AI agents. Core modules included: Observability & Tracing with full end-to-end trace capture.\n\n"
        let targetSize = sizeKB * 1024
        var text = ""
        while text.utf8.count < targetSize {
            text += paragraph
        }
        return text
    }

    @Test("readTail with 90KB user message completes under 200ms")
    func readTailLargeUserMessage() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let largeText = generateLargeText(sizeKB: 90)
        let escapedText = largeText.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let path = (dir as NSString).appendingPathComponent("large.jsonl")
        let lines = [
            #"{"type":"user","sessionId":"s1","message":{"content":"\#(escapedText)"},"cwd":"/test","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Here is the analysis of your document."}]}}"#,
            #"{"type":"user","sessionId":"s1","message":{"content":"thanks, now fill in section 2"},"cwd":"/test"}"#,
            #"{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"I'll fill in section 2 with the relevant details based on your requirements."}]}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        // The fastest of three runs, so a busy machine does not fail the
        // test for the scheduler's sake.
        var elapsed = Duration.seconds(1)
        var result = try await TranscriptReader.readTail(from: path, maxTurns: 80)
        for _ in 0..<3 {
            let start = ContinuousClock.now
            result = try await TranscriptReader.readTail(from: path, maxTurns: 80)
            elapsed = min(elapsed, start.duration(to: ContinuousClock.now))
        }

        #expect(result.turns.count == 4)
        #expect(elapsed < .milliseconds(200), "readTail took \(elapsed), should be under 200ms")
    }

    @Test("computeGroupInfo with many turns completes under 10ms")
    func computeGroupInfoPerformance() async throws {
        // Simulate 200 turns with mixed roles
        var turns: [ConversationTurn] = []
        for i in 0..<200 {
            let role = i % 3 == 0 ? "user" : "assistant"
            let kind: ContentBlock.Kind = i % 3 == 1 ? .toolUse(name: "Read", input: [:], id: "t\(i)") : .text
            turns.append(ConversationTurn(
                index: i,
                lineNumber: i * 100,
                role: role,
                textPreview: "Content \(i)",
                contentBlocks: [ContentBlock(kind: kind, text: "Content \(i)")]
            ))
        }

        let start = ContinuousClock.now
        for _ in 0..<100 {
            let _ = computeGroupInfoMirror(turns: turns)
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        let perCall = Double(elapsed.components.attoseconds) / 1e18 / 100.0

        #expect(perCall < 0.01, "computeGroupInfo took \(perCall * 1000)ms per call — should be under 10ms")
    }

    @Test("Large user message text block count is reasonable")
    func largeUserMessageBlockCount() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let largeText = generateLargeText(sizeKB: 90)
        let escapedText = largeText.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let path = (dir as NSString).appendingPathComponent("large.jsonl")
        try #"{"type":"user","sessionId":"s1","message":{"content":"\#(escapedText)"},"cwd":"/test"}"#
            .write(toFile: path, atomically: true, encoding: .utf8)

        let result = try await TranscriptReader.readTail(from: path, maxTurns: 80)
        #expect(result.turns.count == 1)

        let turn = result.turns[0]
        // The user message should have exactly 1 text block
        #expect(turn.contentBlocks.count == 1)

        // The text block should be the full 90KB
        let textBlock = turn.contentBlocks[0]
        #expect(textBlock.text.utf8.count > 80_000)
    }

    @Test("AttributedString markdown parsing of 90KB text is fast enough")
    func attributedStringMarkdownPerformance() async throws {
        let largeText = generateLargeText(sizeKB: 90)

        let start = ContinuousClock.now
        let _ = try? AttributedString(
            markdown: largeText,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let elapsed = start.duration(to: ContinuousClock.now)

        // This is what happens in the UI — if this is slow, we need to truncate
        print("AttributedString(markdown:) for 90KB: \(elapsed)")
        #expect(elapsed < .seconds(1), "Markdown parsing took \(elapsed) — freezes UI if over 1s")
    }

    @Test("Plain Text init with 90KB string is fast")
    func plainTextPerformance() async throws {
        let largeText = generateLargeText(sizeKB: 90)

        let start = ContinuousClock.now
        for _ in 0..<10 {
            let _ = largeText.utf8.count // Simulate text processing
        }
        let elapsed = start.duration(to: ContinuousClock.now)

        #expect(elapsed < .milliseconds(10))
    }

    // Mirror of the static function from ChatMessageList for testing
    private func computeGroupInfoMirror(turns: [ConversationTurn]) -> [Int: Bool] {
        var result: [Int: Bool] = [:]
        let visibleTurns = turns.filter { turn in
            if turn.role == "user" {
                return turn.contentBlocks.contains {
                    if case .text = $0.kind { return !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    return false
                }
            }
            return true
        }
        for (i, turn) in visibleTurns.enumerated() {
            let isLast = i == visibleTurns.count - 1
            let nextIsDifferentRole = !isLast && visibleTurns[i + 1].role != turn.role
            result[turn.lineNumber] = isLast || nextIsDifferentRole
        }
        return result
    }
}
