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
}
