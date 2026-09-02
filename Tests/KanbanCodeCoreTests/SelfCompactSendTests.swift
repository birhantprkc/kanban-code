import Foundation
import Testing
@testable import KanbanCodeCore

/// A tmux transport with a composer: `paste-buffer` fills it, `Enter` leaves it
/// full while the assistant is busy, and `C-u` empties it.
private final class ComposerTmuxTransport: TmuxTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _composer = ""
    /// While true, Enter does not submit, the way a busy assistant behaves.
    private var _busy: Bool

    init(busy: Bool = true) {
        self._busy = busy
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    var enterPresses: Int {
        calls.filter { $0.first == "send-keys" && $0.last == "Enter" }.count
    }

    var composer: String {
        lock.lock()
        defer { lock.unlock() }
        return _composer
    }

    func setBusy(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _busy = value
    }

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellCommand.Result {
        apply(arguments)
    }

    /// `NSLock` cannot be taken from an async context, so the state change of a
    /// tmux call happens in this synchronous step.
    private func apply(_ arguments: [String]) -> ShellCommand.Result {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(arguments)
        var stdout = ""
        if arguments.first == "paste-buffer" {
            _composer = "You are above the 350k context limit. Compact yourself now."
        } else if arguments.first == "send-keys", arguments.last == "Enter" {
            if !_busy { _composer = "" }
        } else if arguments.first == "send-keys", arguments.last == "C-u" {
            _composer = ""
        } else if arguments.first == "capture-pane" {
            stdout = "\u{276F} \(_composer)"
        }
        return ShellCommand.Result(exitCode: 0, stdout: stdout, stderr: "")
    }

    func writeTempFile(name: String, contents: String) async throws -> String { "/fake/\(name)" }
    func removeTempFile(_ path: String) async {}
    func isAvailable() async -> Bool { true }
}

@Suite("Self-compact send path")
struct SelfCompactSendTests {
    @Test("Giving up on a prompt clears the composer")
    func giveUpClearsComposer() async {
        let transport = ComposerTmuxTransport()
        let tmux = TmuxAdapter(transport: transport)

        await #expect(throws: TmuxError.self) {
            try await tmux.pastePrompt(to: "claude-1", text: "warning", timeout: .seconds(1), abortIf: nil)
        }

        #expect(transport.composer.isEmpty)
        #expect(transport.calls.contains { $0 == ["send-keys", "-t", "claude-1", "C-u"] })
    }

    @Test("A warning that stops being true is dropped instead of pressed again")
    func abortStopsRetries() async throws {
        let transport = ComposerTmuxTransport()
        let tmux = TmuxAdapter(transport: transport)
        let checks = Counter()

        try await tmux.pastePrompt(
            to: "claude-1",
            text: "warning",
            timeout: .seconds(10),
            abortIf: { checks.next() > 1 }
        )

        #expect(transport.composer.isEmpty)
        #expect(transport.enterPresses <= 2)
        #expect(transport.calls.contains { $0 == ["send-keys", "-t", "claude-1", "C-u"] })
    }

    @Test("A submitted prompt is left alone")
    func submittedPromptIsNotCleared() async throws {
        let transport = ComposerTmuxTransport(busy: false)
        let tmux = TmuxAdapter(transport: transport)

        try await tmux.pastePrompt(to: "claude-1", text: "warning", timeout: .seconds(5), abortIf: nil)

        #expect(!transport.calls.contains { $0 == ["send-keys", "-t", "claude-1", "C-u"] })
    }
}

/// Counts how many times the abort check was asked.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
