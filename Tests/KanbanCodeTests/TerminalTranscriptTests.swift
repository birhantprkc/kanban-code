import Foundation
import Testing
import KanbanCodeCore

@testable import KanbanCode

/// The transcript drawn in the skin of the terminal, for a session that is
/// not on the screen: its rows follow the lines Claude Code prints.
@Suite("Terminal transcript skin")
struct TerminalTranscriptTests {
    private func turn(_ index: Int, role: String, _ blocks: [ContentBlock]) -> ConversationTurn {
        ConversationTurn(index: index, lineNumber: index * 10, role: role, textPreview: "", contentBlocks: blocks)
    }

    @Test("A prompt, a message and a tool call each take one row")
    func rowsFollowTheTranscript() {
        let turns = [
            turn(1, role: "user", [ContentBlock(kind: .text, text: "fix the failing test")]),
            turn(2, role: "assistant", [
                ContentBlock(kind: .text, text: "Looking at it."),
                ContentBlock(kind: .toolUse(name: "Read", input: ["file_path": "/repo/a.swift"], id: "t1"), text: "Read(a.swift)"),
            ]),
            turn(3, role: "user", [ContentBlock(kind: .toolResult(toolName: "Read", toolUseId: "t1"), text: "line 1\nline 2")]),
        ]

        let rows = TerminalTranscript.rows(from: turns)

        #expect(rows.count == 3)
        #expect(rows[0] == .user(id: "10:0", text: "fix the failing test"))
        #expect(rows[1] == .assistant(id: "20:0", text: "Looking at it."))
        #expect(rows[2] == .toolCall(
            id: "20:1",
            title: "Read(a.swift)",
            output: TerminalTranscript.Excerpt(text: "line 1\nline 2", hiddenLines: 0)
        ))
    }

    @Test("A tool result shows its first lines and counts the rest")
    func longOutputIsCut() {
        let output = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let turns = [
            turn(1, role: "assistant", [
                ContentBlock(kind: .toolUse(name: "Bash", input: ["command": "ls"], id: "t1"), text: "Bash(list)"),
            ]),
            turn(2, role: "user", [ContentBlock(kind: .toolResult(toolName: "Bash", toolUseId: "t1"), text: output)]),
        ]

        guard case .toolCall(_, let title, let excerpt) = TerminalTranscript.rows(from: turns)[0] else {
            Issue.record("expected a tool call row")
            return
        }
        #expect(title == "Bash(ls)")
        #expect(excerpt?.text == "line 1\nline 2\nline 3\nline 4")
        #expect(excerpt?.hiddenLines == 6)
    }

    @Test("Bash shows the command, and marks a command of several lines")
    func bashTitleUsesTheCommand() {
        let title = TerminalTranscript.toolTitle(
            name: "Bash", input: ["command": "swift build\nswift test", "description": "Build and test"],
            displayText: "Bash(Build and test)")

        #expect(title == "Bash(swift build …)")
        #expect(TerminalTranscript.toolTitle(name: "Grep", input: [:], displayText: "Grep(\"foo\")") == "Grep(\"foo\")")
        #expect(TerminalTranscript.toolTitle(name: "Skill", input: [:], displayText: "  ") == "Skill")
    }

    @Test("Notes of the harness are not drawn as prompts")
    func systemNotes() {
        let turns = [
            turn(1, role: "user", [ContentBlock(kind: .text, text: "✓ Background task done")]),
            turn(2, role: "user", [ContentBlock(kind: .text, text: "[Request interrupted by user]")]),
            turn(3, role: "assistant", [ContentBlock(kind: .planModeEnter, text: "Entered plan mode")]),
        ]

        let rows = TerminalTranscript.rows(from: turns)

        #expect(rows.allSatisfy { if case .system = $0 { return true }; return false })
    }

    @Test("Thinking is cut short and empty blocks are skipped")
    func thinkingAndEmptyBlocks() {
        let turns = [
            turn(1, role: "assistant", [
                ContentBlock(kind: .thinking, text: "a\nb\nc\nd\ne"),
                ContentBlock(kind: .text, text: "   "),
                ContentBlock(kind: .thinking, text: ""),
            ]),
        ]

        let rows = TerminalTranscript.rows(from: turns)

        #expect(rows == [.thinking(id: "10:0", excerpt: TerminalTranscript.Excerpt(text: "a\nb\nc", hiddenLines: 2))])
    }

    @Test("A message of thousands of lines is cut, a normal one is whole")
    func hugeMessageIsCut() {
        let huge = (1...500).map { "line \($0)" }.joined(separator: "\n")

        let cut = TerminalTranscript.messageText(huge)

        #expect(cut.components(separatedBy: "\n").count == TerminalTranscript.messageLineLimit + 1)
        #expect(cut.hasSuffix("… +300 lines"))
        #expect(TerminalTranscript.messageText("short\nmessage") == "short\nmessage")
    }

    @Test("An excerpt cuts a very long line")
    func excerptCutsLongLines() {
        let long = String(repeating: "x", count: TerminalTranscript.outputLineWidth + 5)

        let excerpt = TerminalTranscript.excerpt(long)

        #expect(excerpt.text.count == TerminalTranscript.outputLineWidth + 1)
        #expect(excerpt.text.hasSuffix("…"))
        #expect(excerpt.hiddenLines == 0)
    }

    @Test("Pull request references keep their links")
    func issueRefs() {
        let refs = TerminalTranscript.issueRefs(
            in: "see langwatch/langwatch#7720 and #12", githubBaseURL: "https://github.com/langwatch/kanban-code")

        #expect(refs["langwatch/langwatch#7720"]?.absoluteString == "https://github.com/langwatch/langwatch/pull/7720")
        #expect(refs["#12"]?.absoluteString == "https://github.com/langwatch/kanban-code/pull/12")
    }
}
