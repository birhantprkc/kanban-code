import Foundation
import KanbanCodeCore

/// Which boxd machine a launch or resume goes to.
enum BoxdMachineChoice: Equatable, Hashable {
    /// A new machine from the configured snapshot.
    case newMachine
    /// A machine that already exists, by name.
    case existing(String)

    var machineName: String? {
        if case .existing(let name) = self { return name }
        return nil
    }
}

/// What the launch dialogs need to offer the "run remotely" row.
struct RemoteLaunchOptions {
    var mode: RemoteMode
    /// Mutagen settings, when that mode is configured.
    var mutagen: RemoteSettings?
    /// Boxd settings, when that mode is active.
    var boxd: BoxdSettings?
    /// Machine the card already has.
    var cardMachine: String?
    var cardMachineState: RemoteMachineState?
    /// Where the last session of the card ran, when it ran at all. A card
    /// that was moved to the Mac must not offer its machine again by
    /// itself: the choice of the last run is the one that is offered.
    var lastRunRemote: Bool?
    /// Other machines in the org the user may pick.
    var availableMachines: [String] = []
    /// True when the boxd CLI is installed.
    var boxdAvailable: Bool = true

    /// Whether a project path can run remotely at all in the active mode.
    func canRunRemotely(projectPath: String?) -> Bool {
        switch mode {
        case .boxd:
            return boxd != nil && boxdAvailable
        case .mutagen:
            guard let mutagen, let projectPath else { return false }
            return projectPath.hasPrefix(mutagen.localPath)
        }
    }

    /// Per-project default of the "run remotely" toggle.
    static func defaultRunRemotely(mode: RemoteMode, projectPath: String) -> Bool {
        switch mode {
        case .boxd:
            return UserDefaults.standard.object(forKey: "runOnBoxd_\(projectPath)") as? Bool ?? false
        case .mutagen:
            return UserDefaults.standard.object(forKey: "runRemotely_\(projectPath)") as? Bool ?? true
        }
    }

    /// State of the "run remotely" box when a dialog opens. The last run of
    /// the card wins, then the machine of the card, then the project.
    static func initialRunRemotely(
        lastRunRemote: Bool?, cardMachine: String?, mode: RemoteMode, projectPath: String
    ) -> Bool {
        if let lastRunRemote { return lastRunRemote }
        if cardMachine != nil { return true }
        return defaultRunRemotely(mode: mode, projectPath: projectPath)
    }

    static func rememberRunRemotely(_ value: Bool, mode: RemoteMode, projectPath: String) {
        switch mode {
        case .boxd:
            UserDefaults.standard.set(value, forKey: "runOnBoxd_\(projectPath)")
        case .mutagen:
            UserDefaults.standard.set(value, forKey: "runRemotely_\(projectPath)")
        }
    }
}
