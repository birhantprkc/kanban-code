import KanbanCodeCore
import Testing

@testable import KanbanCode

@MainActor
@Suite("Collapsed history in the chat list")
struct ChatHistoryCollapseTests {

    private static func turn(_ offset: Int, role: String = "user") -> ConversationTurn {
        ConversationTurn(
            index: offset, lineNumber: offset, role: role, textPreview: "t\(offset)",
            contentBlocks: [ContentBlock(kind: .text, text: "t\(offset)")]
        )
    }

    @Test("ranges land between the groups they sit between in the file")
    func rangesInterleaveByOffset() {
        let groups = [[Self.turn(10)], [Self.turn(500)], [Self.turn(900)]]
        let ranges = [
            CollapsedTurnRange(startOffset: 100, endOffset: 500, messageCount: 12),
            CollapsedTurnRange(startOffset: 600, endOffset: 900, messageCount: 7),
        ]

        let rows = ChatTranscript.weaveRows(groups: groups, ranges: ranges)

        #expect(rows.map(\.offset) == [10, 100, 500, 600, 900])
    }

    @Test("a range above everything loaded still draws")
    func leadingRangeDraws() {
        let rows = ChatTranscript.weaveRows(
            groups: [[Self.turn(300)]],
            ranges: [CollapsedTurnRange(startOffset: 0, endOffset: 300, messageCount: 4)]
        )

        #expect(rows.map(\.offset) == [0, 300])
    }

    @Test("no ranges leaves the rows as the groups")
    func noRangesIsIdentity() {
        let groups = [[Self.turn(10)], [Self.turn(20), Self.turn(30)]]

        let rows = ChatTranscript.weaveRows(groups: groups, ranges: [])

        #expect(rows.map(\.offset) == [10, 20])
    }

    /// The jump measures its ceiling from whatever is topmost on screen, and
    /// a collapsed range can be exactly that.
    @Test("a divider on screen can be the top the jump measures from")
    func dividerCountsAsTop() {
        let rows = ChatVisibleRows()
        rows.set(100, visible: true)  // a range's start offset
        rows.set(400, visible: true)  // a turn below it

        #expect(rows.top(among: [100, 400]) == 100)
    }

    // MARK: - Edge transitions

    @Test("a card switch reads as switched even when both ends change at once")
    func cardSwitchIsSwitched() {
        let newTurns = [Self.turn(5), Self.turn(50)]

        let transition = ChatTranscript.edgeTransition(
            oldFirst: 1000, oldLast: 9000, newFirst: 5, newLast: 50,
            lastSeen: 9000, turns: newTurns
        )

        #expect(transition.switched)
    }

    @Test("older turns above plus a live append below stay the same conversation")
    func bothEndsGrowingIsNotASwitch() {
        // 9000 was the last turn we knew. A segment loaded above (new first
        // 100) and the session appended below (new last 9500) in one update.
        let turns = [Self.turn(100), Self.turn(1000), Self.turn(9000), Self.turn(9500)]

        let transition = ChatTranscript.edgeTransition(
            oldFirst: 1000, oldLast: 9000, newFirst: 100, newLast: 9500,
            lastSeen: 9000, turns: turns
        )

        #expect(!transition.switched)
        #expect(transition.appended)
        #expect(transition.prepended)
    }

    @Test("the first content after a reset is not a switch")
    func initialContentIsNotASwitch() {
        let turns = [Self.turn(10), Self.turn(20)]

        let transition = ChatTranscript.edgeTransition(
            oldFirst: nil, oldLast: nil, newFirst: 10, newLast: 20,
            lastSeen: nil, turns: turns
        )

        #expect(!transition.switched)
        #expect(transition.appended)
    }

    @Test("a rewritten transcript that dropped the last known turn is a switch")
    func rewrittenFileIsASwitch() {
        let turns = [Self.turn(10), Self.turn(20)]

        let transition = ChatTranscript.edgeTransition(
            oldFirst: 10, oldLast: 9000, newFirst: 10, newLast: 20,
            lastSeen: 9000, turns: turns
        )

        #expect(transition.switched)
    }

    @Test("a prepend alone keeps the bottom end quiet")
    func prependAloneIsNotAppended() {
        let turns = [Self.turn(100), Self.turn(1000), Self.turn(9000)]

        let transition = ChatTranscript.edgeTransition(
            oldFirst: 1000, oldLast: 9000, newFirst: 100, newLast: 9000,
            lastSeen: 9000, turns: turns
        )

        #expect(!transition.switched)
        #expect(!transition.appended)
        #expect(transition.prepended)
    }
}
