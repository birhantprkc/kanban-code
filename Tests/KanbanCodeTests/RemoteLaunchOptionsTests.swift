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

    private func options(boxdAvailable: Bool = true, cardMachine: String? = nil, available: [String] = []) -> RemoteLaunchOptions {
        RemoteLaunchOptions(
            mode: .boxd,
            boxd: BoxdSettings(snapshotName: "snap", sshMachines: [
                SshMachine(name: "box", target: "root@10.0.0.1"),
                SshMachine(name: "draft", target: ""),
            ]),
            cardMachine: cardMachine,
            availableMachines: available,
            boxdAvailable: boxdAvailable)
    }

    @Test("Run on offers this Mac, the ssh machines with their state, then boxd")
    func runTargets() {
        let targets = RunTargetOption.options(for: options(available: ["kanban-repo-1", "box"]), reachability: ["box": true])
        #expect(targets.map(\.label) == [
            "This Mac",
            "box (online)",
            "boxd: new machine from snapshot snap",
            "boxd: kanban-repo-1",
        ])
        #expect(targets[1].target == .machine(.existing("box")))
        #expect(RunTargetOption.options(for: options(), reachability: ["box": false])[1].label == "box (offline)")
        #expect(RunTargetOption.options(for: options())[1].label == "box (checking)")
        // Without the boxd CLI only the Mac and the ssh machines are left.
        #expect(RunTargetOption.options(for: options(boxdAvailable: false)).map(\.label) == ["This Mac", "box (checking)"])
        #expect(options(boxdAvailable: false).canRunRemotely(projectPath: project))
    }

    @Test("A card on an ssh machine opens on it, and the last pick of a project is kept while it is offered")
    func initialMachine() {
        #expect(options(cardMachine: "box").initialMachineChoice(projectPath: project) == .existing("box"))
        #expect(options().initialMachineChoice(projectPath: project) == .newMachine)
        #expect(options(boxdAvailable: false).initialMachineChoice(projectPath: project) == .existing("box"))
        RemoteLaunchOptions.rememberMachineChoice(.existing("box"), projectPath: project)
        #expect(options().initialMachineChoice(projectPath: project) == .existing("box"))
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
