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

    /// Puts the images on the machine of the session and returns their paths
    /// there, or nil when the session does not run on a machine. The
    /// assistant on a machine cannot read the Mac clipboard, so a prompt
    /// with images points at these paths instead.
    func uploadImages(sessionName: String, imagePaths: [String]) async throws -> [String]?
}
