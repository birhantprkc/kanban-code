import Testing

@testable import KanbanCode

/// Scroll interception is an application-wide event monitor that decides what a
/// scroll belongs to from the terminal's frame, not from a hit test. Anything
/// drawn over a terminal is therefore invisible to it, and a scroll inside the
/// quick search palette was being spent driving tmux copy-mode in the pane
/// underneath, one subprocess per wheel tick.
@Suite("Terminal scroll passthrough", .serialized)
@MainActor
struct ScrollPassthroughTests {

    private func withCleanCache(_ body: (TerminalCache) -> Void) {
        let cache = TerminalCache.shared
        while cache.passesScrollThrough { cache.endScrollPassthrough() }
        body(cache)
        while cache.passesScrollThrough { cache.endScrollPassthrough() }
    }

    @Test("the terminal keeps the wheel when nothing is drawn over it")
    func interceptsByDefault() {
        withCleanCache { cache in
            #expect(cache.passesScrollThrough == false)
        }
    }

    @Test("an overlay takes the wheel while it is up, and gives it back")
    func overlayTakesTheWheel() {
        withCleanCache { cache in
            cache.beginScrollPassthrough()
            #expect(cache.passesScrollThrough)
            cache.endScrollPassthrough()
            #expect(cache.passesScrollThrough == false)
        }
    }

    /// The reason this counts rather than toggles: whichever overlay closed
    /// first would otherwise hand the wheel back while the other is still up.
    @Test("the first overlay to close does not speak for the second")
    func nestedOverlays() {
        withCleanCache { cache in
            cache.beginScrollPassthrough()
            cache.beginScrollPassthrough()
            cache.endScrollPassthrough()
            #expect(cache.passesScrollThrough)
            cache.endScrollPassthrough()
            #expect(cache.passesScrollThrough == false)
        }
    }

    /// SwiftUI is free to send a disappear an overlay never balanced with an
    /// appear, and a negative depth would leave the terminal unable to scroll
    /// for the rest of the session.
    @Test("an unbalanced close cannot drive the count below zero")
    func unbalancedClose() {
        withCleanCache { cache in
            cache.endScrollPassthrough()
            cache.endScrollPassthrough()
            cache.beginScrollPassthrough()
            #expect(cache.passesScrollThrough)
            cache.endScrollPassthrough()
            #expect(cache.passesScrollThrough == false)
        }
    }
}
