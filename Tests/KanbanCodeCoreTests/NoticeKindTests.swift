import Foundation
import Testing

@testable import KanbanCodeCore

/// Every banner used to be posted as an error, so "copied to clipboard" came up
/// wearing the same orange warning triangle as a failed launch.
@Suite("Notice kinds")
struct NoticeKindTests {

    @Test("a plain message is still an error, as every existing caller means it")
    func setErrorStaysAnError() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .setError("Launch failed: nope"))

        #expect(state.notice?.message == "Launch failed: nope")
        #expect(state.notice?.kind == .error)
    }

    @Test("good news can say so")
    func successKind() {
        var state = AppState()
        _ = Reducer.reduce(
            state: &state,
            action: .setNotice("Conversation markdown copied to clipboard", kind: .success)
        )

        #expect(state.notice?.kind == .success)
    }

    @Test("a rejected action is a warning, not a failure")
    func warningKind() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .setNotice("Cannot drop here", kind: .warning))

        #expect(state.notice?.kind == .warning)
    }

    @Test("dismissing clears the banner whichever way it was posted")
    func dismissClears() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .setNotice("pinned", kind: .success))
        _ = Reducer.reduce(state: &state, action: .setError(nil))

        #expect(state.notice == nil)
    }

    @Test("a failure the reducer raises itself is an error")
    func reducerFailuresAreErrors() {
        var state = AppState()
        var link = Link(id: "card_1", name: "a card", projectPath: "/tmp/project")
        link.isLaunching = true
        state.links[link.id] = link

        _ = Reducer.reduce(
            state: &state,
            action: .launchFailed(cardId: "card_1", error: "Connection refused")
        )

        #expect(state.notice?.kind == .error)
        #expect(state.notice?.message == "Launch failed: Connection refused")
    }
}
