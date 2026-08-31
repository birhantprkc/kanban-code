import Foundation

/// Machine operations the reducer asks for through effects. The boxd
/// supervisor implements it; tests use a fake.
public protocol RemoteMachineControl: Sendable {
    /// Pauses a machine. Never throws: a pause that fails is logged and the
    /// inactivity timer or the next quit retries it.
    func pause(machineName: String, reason: RemotePausedReason) async

    /// Removes a machine for good.
    func destroy(machineName: String) async throws

    /// Routes a tmux name to a machine before the session is created there.
    func assignSession(_ sessionName: String, to machineName: String) async

    /// Tells the terminal that a session now exists on a machine, so it
    /// attaches instead of waiting for the marker.
    func markSessionReady(_ sessionName: String, on machineName: String) async

    /// Reconnects a machine the app holds as paused when boxd reports it
    /// running. Returns whether the machine is connected afterwards.
    func reconnectIfRunning(machineName: String) async -> Bool

    /// Puts the images on the machine of the session and returns their paths
    /// there, or nil when the session does not run on a machine. The
    /// assistant on a machine cannot read the Mac clipboard, so a prompt
    /// with images points at these paths instead.
    func uploadImages(sessionName: String, imagePaths: [String]) async throws -> [String]?
}
