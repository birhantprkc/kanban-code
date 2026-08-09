import KanbanCodeCore
import Testing

@testable import KanbanCode

@Suite("Notice banner")
@MainActor
struct NoticeBannerTests {

    @Test("each kind gets its own symbol")
    func symbolPerKind() {
        let success = NoticeBanner(notice: Notice("pinned", kind: .success)) {}
        let warning = NoticeBanner(notice: Notice("cannot drop there", kind: .warning)) {}
        let failure = NoticeBanner(notice: Notice("launch failed", kind: .error)) {}

        #expect(success.symbolName == "checkmark.circle.fill")
        #expect(warning.symbolName == "exclamationmark.triangle.fill")
        #expect(failure.symbolName == "xmark.octagon.fill")
    }

    @Test("it clears itself once its time is up")
    func runsDown() async {
        let countdown = NoticeCountdown(
            lifetime: .milliseconds(60),
            tick: .milliseconds(10),
            isHeld: { false }
        )

        #expect(await countdown.run())
    }

    /// The one moment you want it to stay is while you are reading it or
    /// reaching for the close button.
    @Test("attending to it holds it open")
    func heldStaysOpen() async {
        let countdown = NoticeCountdown(
            lifetime: .milliseconds(60),
            tick: .milliseconds(10),
            isHeld: { true }
        )

        // Given five times its lifetime and it still has not dismissed.
        #expect(await countdown.run(limit: .milliseconds(300)) == false)
    }

    @Test("letting go starts the clock again where it stopped")
    func resumesAfterRelease() async {
        var held = true
        let countdown = NoticeCountdown(
            lifetime: .milliseconds(60),
            tick: .milliseconds(10),
            isHeld: { held }
        )

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            held = false
        }

        #expect(await countdown.run(limit: .seconds(5)))
    }

    @Test("a cancelled countdown dismisses nothing")
    func cancellationDismissesNothing() async {
        let task = Task { @MainActor in
            await NoticeCountdown(
                lifetime: .seconds(30),
                tick: .milliseconds(10),
                isHeld: { false }
            ).run()
        }
        task.cancel()

        #expect(await task.value == false)
    }
}
