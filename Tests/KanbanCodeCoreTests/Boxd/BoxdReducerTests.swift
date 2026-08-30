import Testing
import Foundation
@testable import KanbanCodeCore

/// `Effect` is not `Equatable`, so the tests read the remote effects out of
/// the returned list by pattern.
extension Array where Element == Effect {
    var pausedMachines: [(machine: String, reason: RemotePausedReason)] {
        compactMap {
            guard case .pauseRemoteMachine(let machine, let reason) = $0 else { return nil }
            return (machine, reason)
        }
    }

    var destroyedMachines: [String] {
        compactMap {
            guard case .destroyRemoteMachine(let machine) = $0 else { return nil }
            return machine
        }
    }

    var killedSessions: [String] {
        flatMap { effect -> [String] in
            switch effect {
            case .killTmuxSession(let name): [name]
            case .killTmuxSessions(let names): names
            default: []
            }
        }
    }
}

@Suite("Reducer: boxd cards")
struct BoxdReducerTests {

    // MARK: - Helpers

    private func remoteCard(
        id: String,
        machine: String = "kanban-repo-1",
        sessionName: String? = nil,
        pausedReason: RemotePausedReason? = nil,
        column: KanbanCodeColumn = .inProgress
    ) -> Link {
        Link(
            id: id,
            name: "Remote card",
            projectPath: "/work/repo",
            column: column,
            source: .manual,
            tmuxLink: sessionName.map { TmuxLink(sessionName: $0) },
            isRemote: true,
            remote: RemoteLink(
                machineName: machine,
                remoteProjectPath: "/home/boxd/repo",
                remoteCwd: "/home/boxd/repo",
                remoteHome: "/home/boxd",
                pausedReason: pausedReason
            )
        )
    }

    private func localCard(id: String, sessionName: String? = nil) -> Link {
        Link(
            id: id,
            name: "Local card",
            projectPath: "/work/repo",
            column: .inProgress,
            source: .manual,
            tmuxLink: sessionName.map { TmuxLink(sessionName: $0) }
        )
    }

    private func stateWith(_ links: [Link], machineStates: [String: RemoteMachineState] = [:]) -> AppState {
        var state = AppState()
        for link in links { state.links[link.id] = link }
        state.remoteMachineStates = machineStates
        state.rebuildCards()
        return state
    }

    // MARK: - hasLocalActiveCards

    @Test("A card on a machine does not keep the Mac awake")
    func hasLocalActiveCards() {
        #expect(stateWith([localCard(id: "card_1", sessionName: "repo-card_1")]).hasLocalActiveCards)
        #expect(!stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1")]).hasLocalActiveCards)
        // A card that continued locally keeps its machine record but works here.
        var continued = remoteCard(id: "card_2", sessionName: "repo-card_2")
        continued.isRemote = false
        #expect(stateWith([continued]).hasLocalActiveCards)
        #expect(!stateWith([remoteCard(id: "card_3", column: .done)]).hasLocalActiveCards)
    }

    // MARK: - cardIds(onMachine:)

    @Test("cardIds(onMachine:) lists only the cards of that machine, sorted")
    func cardIdsOnMachine() {
        let state = stateWith([
            remoteCard(id: "card_b", machine: "kanban-repo-1"),
            remoteCard(id: "card_a", machine: "kanban-repo-1"),
            remoteCard(id: "card_c", machine: "kanban-other"),
            localCard(id: "card_d"),
        ])

        #expect(state.cardIds(onMachine: "kanban-repo-1") == ["card_a", "card_b"])
        #expect(state.cardIds(onMachine: "kanban-other") == ["card_c"])
        #expect(state.cardIds(onMachine: "kanban-none").isEmpty)
    }

    // MARK: - killTerminal

    @Test("killTerminal keeps the machine record and pauses the machine")
    func killTerminalKeepsRemoteAndPauses() throws {
        var state = stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1")])

        let effects = Reducer.reduce(state: &state, action: .killTerminal(cardId: "card_1", sessionName: "repo-card_1"))

        let link = try #require(state.links["card_1"])
        #expect(link.tmuxLink == nil)
        #expect(link.remote?.machineName == "kanban-repo-1")
        #expect(link.isRemote == true)
        #expect(effects.pausedMachines.count == 1)
        #expect(effects.pausedMachines[0].machine == "kanban-repo-1")
        #expect(effects.pausedMachines[0].reason == .sessionStopped)
        #expect(effects.destroyedMachines.isEmpty)
    }

    @Test("killTerminal does not pause a machine another card still runs on")
    func killTerminalKeepsSharedMachineRunning() {
        var state = stateWith([
            remoteCard(id: "card_1", sessionName: "repo-card_1"),
            remoteCard(id: "card_2", sessionName: "repo-card_2"),
        ])

        let effects = Reducer.reduce(state: &state, action: .killTerminal(cardId: "card_1", sessionName: "repo-card_1"))

        #expect(effects.pausedMachines.isEmpty)
        #expect(state.links["card_1"]?.remote != nil)
        #expect(state.links["card_2"]?.tmuxLink != nil)
    }

    @Test("killTerminal on a local card emits no remote effect")
    func killTerminalOnLocalCard() {
        var state = stateWith([localCard(id: "card_1", sessionName: "repo-card_1")])

        let effects = Reducer.reduce(state: &state, action: .killTerminal(cardId: "card_1", sessionName: "repo-card_1"))

        #expect(effects.pausedMachines.isEmpty)
        #expect(state.links["card_1"]?.isRemote == false)
    }

    // MARK: - launchFailed and resumeFailed

    @Test("launchFailed keeps the machine record so a retry finds it")
    func launchFailedKeepsRemote() {
        var state = stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1")])

        _ = Reducer.reduce(state: &state, action: .launchFailed(cardId: "card_1", error: "boom"))

        #expect(state.links["card_1"]?.remote?.machineName == "kanban-repo-1")
        #expect(state.links["card_1"]?.tmuxLink == nil)
        #expect(state.notice != nil)
    }

    @Test("resumeFailed keeps the machine record")
    func resumeFailedKeepsRemote() {
        var state = stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1")])

        _ = Reducer.reduce(state: &state, action: .resumeFailed(cardId: "card_1", error: "boom"))

        #expect(state.links["card_1"]?.remote?.machineName == "kanban-repo-1")
        #expect(state.links["card_1"]?.tmuxLink == nil)
    }

    // MARK: - archiveCard

    @Test("archiveCard clears the machine record and destroys the machine")
    func archiveDestroysTheMachine() throws {
        var state = stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1")])

        let effects = Reducer.reduce(state: &state, action: .archiveCard(cardId: "card_1"))

        let link = try #require(state.links["card_1"])
        #expect(link.remote == nil)
        #expect(link.isRemote == false)
        #expect(link.manuallyArchived == true)
        #expect(effects.destroyedMachines == ["kanban-repo-1"])
        #expect(effects.killedSessions == ["repo-card_1"])
    }

    @Test("archiveCard leaves a machine a second card still uses")
    func archiveKeepsSharedMachine() {
        var state = stateWith([
            remoteCard(id: "card_1", sessionName: "repo-card_1"),
            remoteCard(id: "card_2", sessionName: "repo-card_2"),
        ])

        let effects = Reducer.reduce(state: &state, action: .archiveCard(cardId: "card_1"))

        #expect(effects.destroyedMachines.isEmpty)
        // The archived card still gives its machine record up.
        #expect(state.links["card_1"]?.remote == nil)
        #expect(state.links["card_2"]?.remote?.machineName == "kanban-repo-1")
    }

    // MARK: - deleteCard

    @Test("deleteCard destroys the machine of the card it removed")
    func deleteDestroysTheMachine() {
        var state = stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1")])

        let effects = Reducer.reduce(state: &state, action: .deleteCard(cardId: "card_1"))

        #expect(state.links["card_1"] == nil)
        #expect(effects.destroyedMachines == ["kanban-repo-1"])
    }

    @Test("deleteCard leaves a machine a second card still uses")
    func deleteKeepsSharedMachine() {
        var state = stateWith([
            remoteCard(id: "card_1", sessionName: "repo-card_1"),
            remoteCard(id: "card_2", sessionName: "repo-card_2"),
        ])

        let effects = Reducer.reduce(state: &state, action: .deleteCard(cardId: "card_1"))

        #expect(effects.destroyedMachines.isEmpty)
    }

    // MARK: - destroyRemoteMachine(cardId:)

    @Test("destroyRemoteMachine clears the machine and the tmux link of the card")
    func destroyRemoteMachineClearsTheCard() throws {
        var state = stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1")])

        let effects = Reducer.reduce(state: &state, action: .destroyRemoteMachine(cardId: "card_1"))

        let link = try #require(state.links["card_1"])
        #expect(link.remote == nil)
        #expect(link.isRemote == false)
        #expect(link.tmuxLink == nil)
        #expect(link.isLaunching == nil)
        #expect(effects.destroyedMachines == ["kanban-repo-1"])
        #expect(effects.killedSessions == ["repo-card_1"])
    }

    @Test("destroyRemoteMachine on a card with no machine does nothing")
    func destroyRemoteMachineOnLocalCard() {
        var state = stateWith([localCard(id: "card_1", sessionName: "repo-card_1")])

        let effects = Reducer.reduce(state: &state, action: .destroyRemoteMachine(cardId: "card_1"))

        #expect(effects.isEmpty)
        #expect(state.links["card_1"]?.tmuxLink != nil)
    }

    // MARK: - remoteMachineDestroyed

    @Test("remoteMachineDestroyed clears every card of the machine and forgets its state")
    func remoteMachineDestroyedClearsEveryCard() {
        var state = stateWith(
            [
                remoteCard(id: "card_1", sessionName: "repo-card_1"),
                remoteCard(id: "card_2", sessionName: "repo-card_2"),
                remoteCard(id: "card_3", machine: "kanban-other", sessionName: "repo-card_3"),
            ],
            machineStates: ["kanban-repo-1": .connected, "kanban-other": .connected]
        )

        _ = Reducer.reduce(state: &state, action: .remoteMachineDestroyed(machineName: "kanban-repo-1"))

        #expect(state.links["card_1"]?.remote == nil)
        #expect(state.links["card_1"]?.isRemote == false)
        #expect(state.links["card_1"]?.tmuxLink == nil)
        #expect(state.links["card_2"]?.remote == nil)
        #expect(state.links["card_3"]?.remote?.machineName == "kanban-other")
        #expect(state.remoteMachineStates["kanban-repo-1"] == nil)
        #expect(state.remoteMachineStates["kanban-other"] == .connected)
        #expect(state.notice == Notice("Machine kanban-repo-1 destroyed", kind: .success))
    }

    // MARK: - remoteMachineStateChanged

    @Test("A paused machine marks its cards paused with the reason and a time")
    func pausedStateMarksTheCards() throws {
        var state = stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1")])

        _ = Reducer.reduce(state: &state, action: .remoteMachineStateChanged(machineName: "kanban-repo-1", state: .paused(.inactivity)))

        #expect(state.remoteMachineStates["kanban-repo-1"] == .paused(.inactivity))
        let remote = try #require(state.links["card_1"]?.remote)
        #expect(remote.pausedReason == .inactivity)
        #expect(remote.pausedAt != nil)
        #expect(remote.lastStatus == "standby")
    }

    @Test("A connected machine clears the paused reason of its cards")
    func connectedStateClearsThePause() throws {
        var state = stateWith(
            [remoteCard(id: "card_1", sessionName: "repo-card_1", pausedReason: .appQuit)],
            machineStates: ["kanban-repo-1": .paused(.appQuit)]
        )

        _ = Reducer.reduce(state: &state, action: .remoteMachineStateChanged(machineName: "kanban-repo-1", state: .connected))

        #expect(state.remoteMachineStates["kanban-repo-1"] == .connected)
        let remote = try #require(state.links["card_1"]?.remote)
        #expect(remote.pausedReason == nil)
        #expect(remote.pausedAt == nil)
        #expect(remote.lastStatus == "running")
    }

    @Test("A destroyed machine drops its state and the machine record of its cards")
    func destroyedStateClearsTheCards() {
        var state = stateWith(
            [remoteCard(id: "card_1", sessionName: "repo-card_1")],
            machineStates: ["kanban-repo-1": .connected]
        )

        _ = Reducer.reduce(state: &state, action: .remoteMachineStateChanged(machineName: "kanban-repo-1", state: .destroyed))

        #expect(state.remoteMachineStates["kanban-repo-1"] == nil)
        #expect(state.links["card_1"]?.remote == nil)
        #expect(state.links["card_1"]?.isRemote == false)
    }

    @Test("An unreachable machine leaves the machine record of its cards alone")
    func unreachableStateLeavesTheCards() {
        var state = stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1", pausedReason: .systemSleep)])

        _ = Reducer.reduce(state: &state, action: .remoteMachineStateChanged(machineName: "kanban-repo-1", state: .unreachable))

        #expect(state.remoteMachineStates["kanban-repo-1"] == .unreachable)
        #expect(state.links["card_1"]?.remote?.pausedReason == .systemSleep)
    }

    // MARK: - remoteMachineAssigned

    @Test("remoteMachineAssigned puts the machine on the card and marks it remote")
    func remoteMachineAssigned() {
        var state = stateWith([localCard(id: "card_1")])
        let remote = RemoteLink(
            machineName: "kanban-repo-1",
            remoteProjectPath: "/home/boxd/repo",
            remoteCwd: "/home/boxd/repo",
            remoteHome: "/home/boxd"
        )

        let effects = Reducer.reduce(state: &state, action: .remoteMachineAssigned(cardId: "card_1", remote: remote))

        #expect(state.links["card_1"]?.remote == remote)
        #expect(state.links["card_1"]?.isRemote == true)
        #expect(effects.count == 1)
    }

    // MARK: - pauseRemoteMachine(cardId:)

    @Test("pauseRemoteMachine turns a card id into a machine effect")
    func pauseRemoteMachineByCard() {
        var state = stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1")])

        let effects = Reducer.reduce(state: &state, action: .pauseRemoteMachine(cardId: "card_1", reason: .manual))

        #expect(effects.pausedMachines.count == 1)
        #expect(effects.pausedMachines[0].machine == "kanban-repo-1")
        #expect(effects.pausedMachines[0].reason == .manual)
    }

    // MARK: - tmuxLivenessScanned

    @Test("A tmux scan does not clear the session of a card on a paused machine")
    func livenessSkipsPausedMachines() {
        var state = stateWith(
            [remoteCard(id: "card_1", sessionName: "repo-card_1")],
            machineStates: ["kanban-repo-1": .paused(.inactivity)]
        )

        _ = Reducer.reduce(state: &state, action: .tmuxLivenessScanned(live: []))

        #expect(state.links["card_1"]?.tmuxLink?.sessionName == "repo-card_1")
    }

    @Test("A tmux scan does not clear the session of a card whose machine is unknown")
    func livenessSkipsUnknownMachines() {
        var state = stateWith([remoteCard(id: "card_1", sessionName: "repo-card_1")])

        _ = Reducer.reduce(state: &state, action: .tmuxLivenessScanned(live: []))

        #expect(state.links["card_1"]?.tmuxLink?.sessionName == "repo-card_1")
    }

    @Test("A tmux scan clears a dead session of a card on a connected machine")
    func livenessClearsConnectedMachines() {
        var state = stateWith(
            [remoteCard(id: "card_1", sessionName: "repo-card_1")],
            machineStates: ["kanban-repo-1": .connected]
        )

        _ = Reducer.reduce(state: &state, action: .tmuxLivenessScanned(live: []))

        #expect(state.links["card_1"]?.tmuxLink == nil)
    }

    @Test("A tmux scan keeps a live session of a card on a connected machine")
    func livenessKeepsLiveSession() {
        var state = stateWith(
            [remoteCard(id: "card_1", sessionName: "repo-card_1")],
            machineStates: ["kanban-repo-1": .connected]
        )

        _ = Reducer.reduce(state: &state, action: .tmuxLivenessScanned(live: ["repo-card_1"]))

        #expect(state.links["card_1"]?.tmuxLink?.sessionName == "repo-card_1")
    }

    // MARK: - settingsLoaded

    @Test("settingsLoaded carries the remote mode and the boxd settings into the state")
    func settingsLoadedCarriesBoxd() {
        var state = AppState()
        let boxd = BoxdSettings(snapshotName: "kanban-base", sourceMachine: "good-wolf", inactivityTimeoutSeconds: 900)

        _ = Reducer.reduce(state: &state, action: .settingsLoaded(
            projects: [], excludedPaths: [], remote: nil, remoteMode: .boxd, boxd: boxd
        ))

        #expect(state.remoteMode == .boxd)
        #expect(state.boxdSettings == boxd)
        #expect(state.boxdSettings?.inactivityTimeoutSeconds == 900)
    }

    @Test("settingsLoaded without boxd settings clears them")
    func settingsLoadedWithoutBoxd() {
        var state = AppState()
        state.boxdSettings = BoxdSettings()

        _ = Reducer.reduce(state: &state, action: .settingsLoaded(
            projects: [], excludedPaths: [], remote: nil, remoteMode: .mutagen, boxd: nil
        ))

        #expect(state.remoteMode == .mutagen)
        #expect(state.boxdSettings == nil)
    }


    // MARK: - Launch progress

    @Test("launchProgress keeps a launch alive and shows the step")
    func launchProgressKeepsLaunchAlive() throws {
        var link = localCard(id: "card_1", sessionName: "repo-card_1")
        link.isLaunching = true
        link.updatedAt = Date(timeIntervalSinceNow: -120)
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .launchProgress(cardId: "card_1", message: "Creating machine"))

        #expect(effects.isEmpty)
        #expect(state.launchProgress["card_1"] == "Creating machine")
        let updated = try #require(state.links["card_1"])
        #expect(Date.now.timeIntervalSince(updated.updatedAt) < 5)
    }

    @Test("launchProgress is ignored for a card that is not launching")
    func launchProgressIgnoredWhenNotLaunching() {
        var state = stateWith([localCard(id: "card_1", sessionName: "repo-card_1")])

        _ = Reducer.reduce(state: &state, action: .launchProgress(cardId: "card_1", message: "late"))

        #expect(state.launchProgress["card_1"] == nil)
    }

    @Test("launchCompleted and launchFailed drop the progress line")
    func launchEndClearsProgress() {
        var link = localCard(id: "card_1", sessionName: "repo-card_1")
        link.isLaunching = true
        var state = stateWith([link])
        _ = Reducer.reduce(state: &state, action: .launchProgress(cardId: "card_1", message: "step"))
        _ = Reducer.reduce(state: &state, action: .launchTmuxReady(cardId: "card_1"))
        #expect(state.launchProgress["card_1"] == nil)

        var again = localCard(id: "card_2", sessionName: "repo-card_2")
        again.isLaunching = true
        state = stateWith([again])
        _ = Reducer.reduce(state: &state, action: .launchProgress(cardId: "card_2", message: "step"))
        _ = Reducer.reduce(state: &state, action: .launchFailed(cardId: "card_2", error: "boom"))
        #expect(state.launchProgress["card_2"] == nil)
    }

    // MARK: - Reconciled merge

    @Test("A reconciled snapshot without the machine record does not take it away")
    func reconciledKeepsMachineRecord() throws {
        let inMemory = remoteCard(id: "card_1", sessionName: "repo-card_1")
        var state = stateWith([inMemory])

        var snapshot = localCard(id: "card_1", sessionName: "repo-card_1")
        snapshot.updatedAt = Date(timeIntervalSinceNow: 60)
        _ = Reducer.reduce(state: &state, action: .reconciled(ReconciliationResult(
            links: [snapshot], sessions: [], activityMap: [:], tmuxSessions: ["repo-card_1"])))

        let merged = try #require(state.links["card_1"])
        #expect(merged.remote?.machineName == "kanban-repo-1")
        #expect(merged.isRemote == true)
    }

    @Test("A stale launch loses only its flag, not the machine or the worktree")
    func staleLaunchKeepsMachine() throws {
        var inMemory = remoteCard(id: "card_1", sessionName: "repo-card_1")
        inMemory.isLaunching = true
        inMemory.worktreeLink = WorktreeLink(path: "/work/repo/.claude/worktrees/x", branch: "x")
        inMemory.updatedAt = Date(timeIntervalSinceNow: -120)
        var state = stateWith([inMemory])

        var snapshot = localCard(id: "card_1", sessionName: "repo-card_1")
        snapshot.isLaunching = true
        snapshot.updatedAt = Date(timeIntervalSinceNow: -120)
        _ = Reducer.reduce(state: &state, action: .reconciled(ReconciliationResult(
            links: [snapshot], sessions: [], activityMap: [:], tmuxSessions: [])))

        let merged = try #require(state.links["card_1"])
        #expect(merged.isLaunching == nil)
        #expect(merged.remote?.machineName == "kanban-repo-1")
        #expect(merged.worktreeLink?.branch == "x")
    }
}
