import Foundation
import Testing

@testable import KanbanCodeCore

/// The timeout path closes the pipe read handles while the drain threads can
/// still be blocked on them: a timed-out child's own children keep the write
/// end open past the grace wait. NSFileHandle's readDataToEndOfFile reported
/// that close as an ObjC exception no Swift catch can stop, and one timed-out
/// `gh` call took the whole app down with SIGABRT.
@Suite("Shell command timeout close race", .serialized)
struct ShellCommandTimeoutCrashTests {

    @Test("a timeout on a child that outlives SIGTERM does not abort the process")
    func timeoutWithHeldPipeDoesNotAbort() async {
        // The shell ignores the timeout's SIGTERM and keeps streaming to its
        // stdout past the 5s grace wait, so the drain thread calls read on a
        // handle the timeout path already closed — the exact call the crash
        // fired from. Streaming (not one blocked read) matters: a reader
        // parked inside a single read never observes the close, only a fresh
        // read call does.
        await #expect(throws: ShellCommandError.self) {
            _ = try await ShellCommand.run(
                "/bin/sh",
                arguments: ["-c", "trap '' TERM; for i in $(seq 70); do echo data; sleep 0.1; done"],
                timeout: 0.3
            )
        }
        // The abort fired from the drain thread a beat after the throw. Give
        // it that beat, then prove the process still runs commands.
        try? await Task.sleep(for: .milliseconds(500))
        let result = try? await ShellCommand.run("/bin/echo", arguments: ["alive"])
        #expect(result?.stdout == "alive")
    }
}
