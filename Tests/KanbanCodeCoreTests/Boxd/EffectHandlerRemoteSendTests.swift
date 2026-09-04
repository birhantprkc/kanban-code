import Foundation
import Testing
@testable import KanbanCodeCore

/// Records what the send effects ask of the machines and of tmux.
private final class RecordingRemoteControl: RemoteMachineControl, @unchecked Sendable {
    private let lock = NSLock()
    private var _resumedSessions: [String] = []
    let comesBack: Bool

    init(comesBack: Bool = true) {
        self.comesBack = comesBack
    }

    var resumedSessions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _resumedSessions
    }

    func resumeMachine(forSession sessionName: String) async -> Bool {
        record(sessionName)
        return comesBack
    }

    private func record(_ sessionName: String) {
        lock.lock()
        defer { lock.unlock() }
        _resumedSessions.append(sessionName)
    }

    func stop(machineName: String) async {}
    func stop(machineName: String, reason: RemotePausedReason) async {}
    func destroy(machineName: String) async throws {}
    func assignSession(_ sessionName: String, to machineName: String) async {}
    func markSessionReady(_ sessionName: String, on machineName: String) async {}
    func resume(machineName: String) async -> Bool { comesBack }
    func pauseIfPeek(machineName: String) async {}
    func reconnectIfRunning(machineName: String) async -> Bool { comesBack }
    func uploadImages(sessionName: String, imagePaths: [String]) async throws -> [String]? { nil }
}

private final class RecordingTmux: TmuxManagerPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(session: String, text: String)] = []

    var sent: [(session: String, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    private func record(_ session: String, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        _sent.append((session, text))
    }

    func listSessions() async throws -> [TmuxSession] { [] }
    func createSession(name: String, path: String, command: String?) async throws {}
    func killSession(name: String) async throws {}
    func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
    func sendPrompt(to sessionName: String, text: String) async throws { record(sessionName, text) }
    func pastePrompt(to sessionName: String, text: String) async throws { record(sessionName, text) }
    func pasteText(to sessionName: String, text: String) async throws {}
    func submitPrompt(to sessionName: String) async throws {}
    func capturePane(sessionName: String) async throws -> String { "" }
    func sendBracketedPaste(to sessionName: String) async throws {}
    func isAvailable() async -> Bool { true }
}

@Suite("Prompts to a session on a paused machine")
struct EffectHandlerRemoteSendTests {
    private func handler(control: RecordingRemoteControl, tmux: RecordingTmux) -> EffectHandler {
        let dir = NSTemporaryDirectory() + "kanban-effect-\(UUID().uuidString)"
        return EffectHandler(
            coordinationStore: CoordinationStore(basePath: dir),
            tmuxAdapter: tmux,
            remoteMachines: control
        )
    }

    @Test("The machine is brought back before the prompt is pasted")
    func resumesThenSends() async {
        let control = RecordingRemoteControl()
        let tmux = RecordingTmux()

        await handler(control: control, tmux: tmux).execute(
            .sendPromptToTmux(sessionName: "claude-1", promptBody: "go on", assistant: .claude),
            dispatch: { _ in }
        )

        #expect(control.resumedSessions == ["claude-1"])
        #expect(tmux.sent.map(\.text) == ["go on"])
    }

    @Test("A machine that does not come back gets no prompt")
    func noSendWithoutMachine() async {
        let control = RecordingRemoteControl(comesBack: false)
        let tmux = RecordingTmux()

        await handler(control: control, tmux: tmux).execute(
            .sendPromptToTmux(sessionName: "claude-1", promptBody: "go on", assistant: .claude),
            dispatch: { _ in }
        )

        #expect(control.resumedSessions == ["claude-1"])
        #expect(tmux.sent.isEmpty)
    }

    @Test("A prompt with images waits for the machine too")
    func imagesResumeFirst() async {
        let control = RecordingRemoteControl(comesBack: false)
        let tmux = RecordingTmux()

        await handler(control: control, tmux: tmux).execute(
            .sendPromptWithImagesToTmux(sessionName: "claude-1", promptBody: "look", imagePaths: [], assistant: .claude),
            dispatch: { _ in }
        )

        #expect(control.resumedSessions == ["claude-1"])
        #expect(tmux.sent.isEmpty)
    }
}
