import Foundation

/// Machine operations the reducer asks for through effects. The boxd
/// supervisor implements it; tests use a fake.
public protocol RemoteMachineControl: Sendable {
    /// Stops a machine, for a card whose work is over. Never throws: a stop
    /// that fails is logged, and the next sweep or quit retries it.
    func stop(machineName: String) async

    /// Stops a machine and keeps the reason for the card's banner.
    func stop(machineName: String, reason: RemotePausedReason) async

    /// Removes a machine for good.
    func destroy(machineName: String) async throws

    /// Routes a tmux name to a machine before the session is created there.
    func assignSession(_ sessionName: String, to machineName: String) async

    /// Tells the terminal that a session now exists on a machine, so it
    /// attaches instead of waiting for the marker.
    func markSessionReady(_ sessionName: String, on machineName: String) async

    /// Takes a machine out of standby for a person: the card came into
    /// focus, or a click reached its terminal. Returns whether the machine
    /// is connected afterwards.
    func resume(machineName: String) async -> Bool

    /// Stops a machine a person brought back but did nothing with, when
    /// its card leaves focus.
    func pauseIfPeek(machineName: String) async

    /// Takes the machine of a session out of standby before a prompt is
    /// sent to it, and counts the prompt as work on the machine. Returns
    /// false when the machine did not come back. A session that is not on
    /// a machine returns true.
    func resumeMachine(forSession sessionName: String) async -> Bool

    /// Reconnects a machine the app holds as paused when boxd reports it
    /// running. Returns whether the machine is connected afterwards.
    func reconnectIfRunning(machineName: String) async -> Bool

    /// Puts the images on the machine of the session and returns their paths
    /// there, or nil when the session does not run on a machine. The
    /// assistant on a machine cannot read the Mac clipboard, so a prompt
    /// with images points at these paths instead.
    func uploadImages(sessionName: String, imagePaths: [String]) async throws -> [String]?
}
