import Foundation
import Testing

@testable import KanbanCodeCore

/// These pin the invariant rather than reproduce the original failure: the
/// accumulation was measured in the running app, and the same pattern leaks two
/// descriptors per call in a standalone binary, but it does not accumulate
/// inside this test process, where the objects happen to be released promptly.
/// When they are released is exactly what a scarce process-wide resource cannot
/// be left to depend on.
///
/// A descriptor held after a child is gone is not just this app's problem. The
/// kernel caps how much buffer memory all pipes on the machine may use, and past
/// roughly half that cap XNU quietly hands every newly created pipe a 512 byte
/// buffer instead of 16KB. Unrelated programs that write more than that to a
/// pipe before anything reads it then block forever. One customer report traced
/// a VPN client stuck at "Connecting..." for weeks back to exactly this, and
/// rebooting only helped because it cleared the leak.
@Suite("Shell command file descriptors", .serialized)
struct ShellCommandDescriptorTests {

    /// Counts this process's open pipe descriptors. `lsof` reports the same
    /// number, but asking the kernel directly keeps the test hermetic.
    private static func openPipeCount() -> Int {
        var count = 0
        for fd in 0..<1024 {
            var info = stat()
            guard fstat(Int32(fd), &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFIFO { count += 1 }
        }
        return count
    }

    /// The lowest count seen over a short window.
    ///
    /// The whole test binary shares one process, and suites run in parallel, so
    /// at any instant the count includes descriptors that other tests' children
    /// are legitimately using. Those come and go; a leak does not. Sampling the
    /// minimum sees through the traffic. The suite is serialized on top of that,
    /// because these tests spawn hard enough to read as each other's leaks.
    private static func settledPipeCount() async -> Int {
        var lowest = Int.max
        for _ in 0..<6 {
            lowest = min(lowest, openPipeCount())
            try? await Task.sleep(for: .milliseconds(15))
        }
        return lowest
    }

    /// Runs `body` once to settle any lazy setup, then many more times, and
    /// fails if the descriptors grew with the repetitions. The slack is wide on
    /// purpose. A leak is not subtle by comparison with the noise: the smallest
    /// one cost two descriptors per call, so `repetitions` of it lands far past
    /// the slack, while another suite's children in flight never do. Counting to
    /// the descriptor instead would only buy a test that fails on its own.
    private static func expectNoDescriptorGrowth(
        repetitions: Int = 15,
        slack: Int = 8,
        _ body: () async -> Void
    ) async {
        await body()
        let baseline = await settledPipeCount()

        for _ in 0..<repetitions {
            await body()
        }

        let after = await settledPipeCount()
        #expect(
            after <= baseline + slack,
            "\(after - baseline) pipe descriptors held after \(repetitions) runs"
        )
    }

    @Test("running commands does not accumulate pipe descriptors")
    func descriptorCountIsStableAcrossRuns() async {
        await Self.expectNoDescriptorGrowth {
            _ = try? await ShellCommand.run("/bin/echo", arguments: ["hello"])
        }
    }

    @Test("a command that writes nothing still gives its descriptors back")
    func silentCommandDoesNotLeak() async {
        await Self.expectNoDescriptorGrowth {
            _ = try? await ShellCommand.run("/usr/bin/true")
        }
    }

    @Test("piping stdin gives its descriptors back too")
    func stdinDoesNotLeak() async {
        await Self.expectNoDescriptorGrowth {
            let result = try? await ShellCommand.run("/bin/cat", stdin: "hello")
            #expect(result?.stdout == "hello")
        }
    }

    /// The timeout path used to return without reaping or closing, so every
    /// wedged command cost two descriptors and left a zombie behind.
    @Test("a command that times out is reaped and gives its descriptors back")
    func timeoutDoesNotLeak() async {
        await Self.expectNoDescriptorGrowth(repetitions: 8, slack: 6) {
            _ = try? await ShellCommand.run(
                "/bin/sleep", arguments: ["30"], timeout: 0.2)
        }
    }

    @Test("a command that cannot launch gives its descriptors back")
    func failedLaunchDoesNotLeak() async {
        await Self.expectNoDescriptorGrowth {
            _ = try? await ShellCommand.run("/nonexistent/binary")
        }
    }

    @Test("a command that times out still reports the timeout")
    func timeoutStillThrows() async {
        await #expect(throws: ShellCommandError.self) {
            _ = try await ShellCommand.run("/bin/sleep", arguments: ["30"], timeout: 0.2)
        }
    }

    /// A report of this app holding a hundred unreaped children came in with the
    /// descriptor leak. Foundation collects a `Process` on its own, so this pins
    /// that the timeout path does not get in the way of that.
    @Test("a command that times out leaves no zombie behind")
    func timeoutReapsTheChild() async {
        for _ in 0..<3 {
            _ = try? await ShellCommand.run("/bin/sleep", arguments: ["30"], timeout: 0.2)
        }
        // Reaping is what the parent does after the child dies, and the child
        // dies on its own clock, so give it a moment to settle.
        var zombies = Self.zombieChildCount()
        for _ in 0..<20 where zombies > 0 {
            try? await Task.sleep(for: .milliseconds(50))
            zombies = Self.zombieChildCount()
        }
        #expect(zombies == 0, "\(zombies) unreaped children after 3 timed-out commands")
    }

    /// Draining after waiting deadlocks as soon as a child writes more than one
    /// pipe buffer: it blocks on the write, so it never exits, so the wait never
    /// returns. Two spots in the app did exactly that.
    @Test("a command that outgrows a pipe buffer still finishes")
    func largeOutputDoesNotDeadlock() async throws {
        let result = try await ShellCommand.run(
            "/bin/dd",
            arguments: ["if=/dev/zero", "bs=1024", "count=2048"],
            timeout: 20
        )
        #expect(result.succeeded)
        // Both streams have to be drained concurrently: dd writes the bytes to
        // stdout and its summary to stderr.
        #expect(result.stdout.count >= 2 * 1024 * 1024 - 1)
    }

    private static func zombieChildCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=,stat=", "-ax"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        defer { try? pipe.fileHandleForReading.close() }
        guard (try? process.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let mine = String(ProcessInfo.processInfo.processIdentifier)
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .filter { line in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                return parts.count >= 2 && parts[0] == mine && parts[1].hasPrefix("Z")
            }
            .count
    }
}
