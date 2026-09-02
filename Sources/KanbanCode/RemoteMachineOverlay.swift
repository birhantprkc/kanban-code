import Foundation
import KanbanCodeCore

/// What the assistant tab shows over a live session whose boxd machine is
/// not connected.
enum RemoteMachineOverlayState: Equatable {
    /// The machine is connected, or the card has no machine: the terminal shows.
    case none
    /// The machine is in standby or stopped. A person brings it back.
    case paused(RemotePausedReason)
    /// The last resume did not reach the machine. A person tries again.
    case unreachable
    /// A resume is in flight.
    case resuming

    /// Whether the overlay offers a resume.
    var canResume: Bool {
        switch self {
        case .paused, .unreachable: true
        case .none, .resuming: false
        }
    }
}

enum RemoteMachineOverlay {
    /// The overlay for a card, from what the app knows about its machine.
    /// The supervisor state wins; the pause reason stored on the link stands
    /// in for it when the supervisor has not reported yet, right after start.
    static func state(
        remote: RemoteLink?,
        machineState: RemoteMachineState?,
        hasLiveSession: Bool
    ) -> RemoteMachineOverlayState {
        guard hasLiveSession, let remote, remote.mode == .boxd else { return .none }
        switch machineState {
        case .paused(let reason): return .paused(reason)
        case .unreachable: return .unreachable
        case .connecting: return .resuming
        case .connected, .destroyed: return .none
        case nil: return remote.pausedReason.map { .paused($0) } ?? .none
        }
    }

    /// The line shown next to the resume button.
    static func text(
        for state: RemoteMachineOverlayState,
        remote: RemoteLink,
        lastActivity: Date?
    ) -> String {
        let machine = remote.machineName
        switch state {
        case .none:
            return ""
        case .resuming:
            return "Resuming machine \(machine)…"
        case .unreachable:
            return "Machine \(machine) did not answer. Resume tries again."
        case .paused(let reason):
            switch reason {
            case .inactivity:
                // How long the machine sat idle: from the last activity of the
                // card to the moment it was paused.
                var minutes = 60
                if let pausedAt = remote.pausedAt, let lastActivity, pausedAt > lastActivity {
                    minutes = max(1, Int(pausedAt.timeIntervalSince(lastActivity) / 60))
                }
                return "Machine \(machine) was paused due to inactivity for over \(durationText(minutes: minutes))"
            case .sessionStopped:
                return "Machine \(machine) paused after the session stopped"
            case .stopped:
                return "Machine \(machine) was stopped. Resume starts it again."
            case .appQuit:
                return "Machine \(machine) paused when the app quit"
            case .systemSleep:
                return "Machine \(machine) paused when the Mac went to sleep"
            case .manual:
                return "Machine \(machine) paused"
            }
        }
    }

    static func durationText(minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1h" : "\(hours)h"
        }
        return "\(minutes) min"
    }
}
