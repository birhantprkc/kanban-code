import KanbanCodeCore
import Testing

@testable import KanbanCode

@MainActor
@Suite("A finished run of tool calls stands behind one line")
struct ChatToolRunCollapseTests {

    private static func toolTurn(_ lineNumber: Int, calls: Int = 1) -> ConversationTurn {
        ConversationTurn(
            index: lineNumber, lineNumber: lineNumber, role: "assistant", textPreview: "",
            contentBlocks: (0..<calls).map { i in
                ContentBlock(kind: .toolUse(name: "Read", input: [:], id: "t\(lineNumber)-\(i)"), text: "Read a.ts")
            }
        )
    }

    @Test("the run being worked on stays as it is")
    func newestRunStaysOpen() {
        #expect(
            !CollapsedToolRunCard.collapses(
                callCount: 30, isNewestRun: true, holdsSearchMatch: false))
    }

    @Test("a run behind the newest one stands behind its marker")
    func finishedRunCollapses() {
        #expect(
            CollapsedToolRunCard.collapses(
                callCount: 15, isNewestRun: false, holdsSearchMatch: false))
    }

    @Test("a short run is left alone")
    func shortRunStaysOpen() {
        #expect(
            !CollapsedToolRunCard.collapses(
                callCount: 2, isNewestRun: false, holdsSearchMatch: false))
        #expect(
            CollapsedToolRunCard.collapses(
                callCount: 3, isNewestRun: false, holdsSearchMatch: false))
    }

    @Test("a run holding the search match opens whatever its age")
    func searchMatchWins() {
        #expect(
            !CollapsedToolRunCard.collapses(
                callCount: 20, isNewestRun: false, holdsSearchMatch: true))
    }

    @Test("the count is of tool calls, not of turns")
    func countsCallsNotTurns() {
        let run = [Self.toolTurn(10), Self.toolTurn(20, calls: 3), Self.toolTurn(30, calls: 2)]

        #expect(ChatTranscript.toolCallCount(in: run) == 6)
    }

    @Test("text in a turn is not a tool call")
    func textIsNotCounted() {
        let turn = ConversationTurn(
            index: 1, lineNumber: 10, role: "assistant", textPreview: "",
            contentBlocks: [
                ContentBlock(kind: .text, text: "Done."),
                ContentBlock(kind: .toolUse(name: "Read", input: [:], id: "t1"), text: "Read a.ts"),
            ]
        )

        #expect(ChatTranscript.toolCallCount(in: [turn]) == 1)
    }
}
