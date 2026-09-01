import Foundation

/// What the app knows about a remote machine right now. Not persisted: the
/// supervisor rebuilds it from the boxd CLI and the bridge at startup.
public enum RemoteMachineState: Sendable, Equatable {
    /// The machine is starting or the bridge is being opened.
    case connecting
    /// The bridge is open and tmux commands reach the machine.
    case connected
    /// The machine is paused; its tmux sessions are kept in memory.
    case paused(RemotePausedReason)
    /// The machine exists but the bridge cannot reach it.
    case unreachable
    /// The machine was removed.
    case destroyed

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    public var pausedReason: RemotePausedReason? {
        if case .paused(let reason) = self { return reason }
        return nil
    }

    /// Short text for badges and menus.
    public var label: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        // A stopped machine is off, not in standby: it says so on its own.
        case .paused(.stopped): "Stopped"
        case .paused(let reason): "Paused (\(reason.label))"
        case .unreachable: "Unreachable"
        case .destroyed: "Destroyed"
        }
    }
}

extension RemotePausedReason {
    public var label: String {
        switch self {
        case .sessionStopped: "session stopped"
        case .stopped: "stopped"
        case .inactivity: "inactivity"
        case .appQuit: "app quit"
        case .systemSleep: "system sleep"
        case .manual: "manual"
        }
    }
}
