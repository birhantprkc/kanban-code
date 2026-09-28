import Foundation
import Testing

@testable import KanbanCode
@testable import KanbanCodeCore

/// The launch dialogs offer the choice of the last run of the card. A card
/// that was moved to the Mac keeps its machine, and must not send the next
/// session back to it without being asked.
@Suite("Remote launch options")
struct RemoteLaunchOptionsTests {

    private let project = "/tmp/kanban-tests-\(UUID().uuidString)"

    @Test("the last run of the card decides the box")
    func lastRunWins() {
        #expect(RemoteLaunchOptions.initialRunRemotely(
            lastRunRemote: false, cardMachine: "kanban-repo-1", mode: .boxd, projectPath: project) == false)
        #expect(RemoteLaunchOptions.initialRunRemotely(
            lastRunRemote: true, cardMachine: "kanban-repo-1", mode: .boxd, projectPath: project) == true)
        // A machine kept for a card that ran on the Mac last is still offered
        // in the picker, it is just not chosen.
        #expect(RemoteLaunchOptions.initialRunRemotely(
            lastRunRemote: true, cardMachine: nil, mode: .boxd, projectPath: project) == true)
    }

    @Test("a card that never ran follows its machine, then the project")
    func firstRunFollowsTheMachine() {
        #expect(RemoteLaunchOptions.initialRunRemotely(
            lastRunRemote: nil, cardMachine: "kanban-repo-1", mode: .boxd, projectPath: project) == true)
        // No machine, no run: the project default, which is off for boxd and
        // on for the mutagen mode.
        #expect(RemoteLaunchOptions.initialRunRemotely(
            lastRunRemote: nil, cardMachine: nil, mode: .boxd, projectPath: project) == false)
        #expect(RemoteLaunchOptions.initialRunRemotely(
            lastRunRemote: nil, cardMachine: nil, mode: .mutagen, projectPath: project) == true)
    }

    private func options(mode: RemoteMode = .boxd, boxdAvailable: Bool = true, cardMachine: String? = nil, available: [String] = []) -> RemoteLaunchOptions {
        RemoteLaunchOptions(
            mode: mode,
            boxd: BoxdSettings(snapshotName: "snap", sshMachines: [
                SshMachine(name: "box", target: "root@10.0.0.1"),
                SshMachine(name: "draft", target: ""),
            ]),
            cardMachine: cardMachine,
            availableMachines: available,
            boxdAvailable: boxdAvailable)
    }

    @Test("Run on offers this Mac and the ssh machines with their state in the ssh mode")
    func runTargetsSsh() {
        let targets = RunTargetOption.options(for: options(mode: .ssh, available: ["kanban-repo-1"]), reachability: ["box": true])
        #expect(targets.map(\.label) == ["This Mac", "box (online)"])
        #expect(targets[1].target == .machine(.existing("box")))
        #expect(RunTargetOption.options(for: options(mode: .ssh), reachability: ["box": false])[1].label == "box (offline)")
        #expect(RunTargetOption.options(for: options(mode: .ssh))[1].label == "box (checking)")
        #expect(options(mode: .ssh, boxdAvailable: false).canRunRemotely(projectPath: project))
    }

    @Test("Run on offers this Mac and the boxd machines in the boxd mode")
    func runTargetsBoxd() {
        let targets = RunTargetOption.options(for: options(available: ["kanban-repo-1", "box"]))
        #expect(targets.map(\.label) == [
            "This Mac",
            "boxd: new machine from snapshot snap",
            "boxd: kanban-repo-1",
        ])
        // Without the boxd CLI only the Mac is left, and nothing runs remotely.
        #expect(RunTargetOption.options(for: options(boxdAvailable: false)).map(\.label) == ["This Mac"])
        #expect(!options(boxdAvailable: false).canRunRemotely(projectPath: project))
        // A card already on an ssh machine keeps its machine on offer.
        #expect(RunTargetOption.options(for: options(cardMachine: "box")).map(\.label).last == "box")
    }

    @Test("A card on a machine opens on it, and the last pick of a project is kept while it is offered")
    func initialMachine() {
        #expect(options(cardMachine: "box").initialMachineChoice(projectPath: project) == .existing("box"))
        #expect(options().initialMachineChoice(projectPath: project) == .newMachine)
        #expect(options(mode: .ssh).initialMachineChoice(projectPath: project) == .existing("box"))
        #expect(options(boxdAvailable: false).initialMachineChoice(projectPath: project) == .existing("box"))
        RemoteLaunchOptions.rememberMachineChoice(.existing("kanban-repo-1"), projectPath: project)
        #expect(options(available: ["kanban-repo-1"]).initialMachineChoice(projectPath: project) == .existing("kanban-repo-1"))
        RemoteLaunchOptions.rememberMachineChoice(.existing("gone"), projectPath: project)
        #expect(options().initialMachineChoice(projectPath: project) == .newMachine)
        UserDefaults.standard.removeObject(forKey: "runOnMachine_\(project)")
    }

    @Test("A task from the remote API runs where it asks: the Mac, a machine, or the project default")
    func remoteTaskMachine() {
        let opts = options()
        #expect(RemoteLaunchOptions.remoteMachineChoice("mac", options: opts, projectPath: project) == (false, nil))
        let box = RemoteLaunchOptions.remoteMachineChoice("box", options: opts, projectPath: project)
        #expect(box.runRemotely && box.machine == .existing("box"))
        // The project default of boxd is off.
        #expect(RemoteLaunchOptions.remoteMachineChoice(nil, options: opts, projectPath: project) == (false, nil))
    }
}
