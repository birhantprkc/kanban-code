import Foundation
import Testing
import KanbanCodeCore

@testable import KanbanCode

/// What the assistant tab shows over a live session whose machine is not
/// connected, and when Cmd+Enter goes to the machine instead of the assistant.
@Suite("Remote machine overlay")
struct RemoteMachineOverlayTests {
    private let remote = RemoteLink(mode: .boxd, machineName: "kanban-langwatch-3ii7zfnu")

    @Test("A paused machine under a live session offers a resume")
    func pausedMachine() {
        let state = RemoteMachineOverlay.state(remote: remote, machineState: .paused(.inactivity), hasLiveSession: true, isRemote: true)

        #expect(state == .paused(.inactivity))
        #expect(state.canResume)
    }

    @Test("A resume in flight shows work, not a button")
    func resuming() {
        let state = RemoteMachineOverlay.state(remote: remote, machineState: .connecting, hasLiveSession: true, isRemote: true)

        #expect(state == .resuming)
        #expect(!state.canResume)
        #expect(RemoteMachineOverlay.text(for: state, remote: remote, lastActivity: nil)
            == "Resuming machine kanban-langwatch-3ii7zfnu…")
    }

    @Test("A machine that did not answer can be tried again")
    func unreachable() {
        let state = RemoteMachineOverlay.state(remote: remote, machineState: .unreachable, hasLiveSession: true, isRemote: true)

        #expect(state == .unreachable)
        #expect(state.canResume)
    }

    @Test("A connected machine, a dead session or a local card show nothing")
    func nothingToShow() {
        #expect(RemoteMachineOverlay.state(remote: remote, machineState: .connected, hasLiveSession: true, isRemote: true) == .none)
        #expect(RemoteMachineOverlay.state(remote: remote, machineState: .paused(.inactivity), hasLiveSession: false, isRemote: true) == .none)
        #expect(RemoteMachineOverlay.state(remote: nil, machineState: nil, hasLiveSession: true, isRemote: true) == .none)
        let mutagen = RemoteLink(mode: .mutagen, machineName: "host")
        #expect(RemoteMachineOverlay.state(remote: mutagen, machineState: .paused(.manual), hasLiveSession: true, isRemote: true) == .none)
    }

    @Test("A card that kept its machine but resumed locally gets its terminal")
    func localSessionWithKeptMachine() {
        var paused = remote
        paused.pausedReason = .sessionStopped
        #expect(RemoteMachineOverlay.state(
            remote: paused, machineState: .paused(.sessionStopped), hasLiveSession: true, isRemote: false) == .none)
    }

    @Test("Before the supervisor reports, the pause stored on the link counts")
    func linkPauseStandsIn() {
        var paused = remote
        paused.pausedReason = .appQuit

        #expect(RemoteMachineOverlay.state(remote: paused, machineState: nil, hasLiveSession: true, isRemote: true) == .paused(.appQuit))
        #expect(RemoteMachineOverlay.state(remote: remote, machineState: nil, hasLiveSession: true, isRemote: true) == .none)
    }

    @Test("The inactivity line says how long the machine sat idle")
    func inactivityText() {
        var paused = remote
        paused.pausedAt = Date(timeIntervalSince1970: 10_000)
        let lastActivity = Date(timeIntervalSince1970: 10_000 - 45 * 60)

        let text = RemoteMachineOverlay.text(for: .paused(.inactivity), remote: paused, lastActivity: lastActivity)

        #expect(text == "Machine kanban-langwatch-3ii7zfnu was stopped after 45 min without activity")
        #expect(RemoteMachineOverlay.text(for: .paused(.stopped), remote: remote, lastActivity: nil)
            == "Machine kanban-langwatch-3ii7zfnu was stopped. Resume starts it again.")
    }
}
