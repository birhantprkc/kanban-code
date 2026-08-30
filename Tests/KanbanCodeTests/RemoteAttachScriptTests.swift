import Foundation
import Testing

@testable import KanbanCode

/// The embedded terminal of a remote card opens when the launch starts, while
/// the machine may still be created and the repository checked out. It must
/// wait for the launch to say the tmux session exists before it attaches.
@Suite("Remote attach script")
@MainActor
struct RemoteAttachScriptTests {

    @Test("the attach waits for the ready marker before it tries the machine")
    func waitsForMarker() {
        let script = TerminalCache.remoteAttachScript(
            boxd: "/usr/local/bin/boxd",
            machine: "kanban-repo-1",
            session: "repo-card_1",
            readyMarker: "/Users/me/.kanban-code/remote-ready/repo-card_1"
        )
        let waitIndex = script.range(of: "[ -e '/Users/me/.kanban-code/remote-ready/repo-card_1' ] && break")
        let attachIndex = script.range(of: "machine exec --tty \"$m\" -- tmux attach-session -t 'repo-card_1'")
        #expect(script.contains("m=\"$(cat '/Users/me/.kanban-code/remote-ready/repo-card_1' 2>/dev/null)\"; [ -n \"$m\" ] || m='kanban-repo-1'"))
        #expect(waitIndex != nil)
        #expect(attachIndex != nil)
        if let waitIndex, let attachIndex {
            #expect(waitIndex.lowerBound < attachIndex.lowerBound)
        }
        #expect(script.hasSuffix("echo 'Session ended.'"))
    }

    @Test("without a marker the attach is retried right away")
    func noMarker() {
        let script = TerminalCache.remoteAttachScript(boxd: "boxd", machine: "kanban-repo-1", session: "s")
        #expect(!script.contains("remote-ready"))
        #expect(script.hasPrefix("m='kanban-repo-1'; for i in $(seq 1 30); do"))
    }

    @Test("a terminal that starts before the machine is known takes the machine from the marker")
    func machineFromMarker() {
        let script = TerminalCache.remoteAttachScript(
            boxd: "boxd", machine: nil, session: "s", readyMarker: "/tmp/marker")
        #expect(script.contains("m=\"$(cat '/tmp/marker' 2>/dev/null)\"; [ -n \"$m\" ] || m=''"))
        #expect(script.contains("machine exec --tty \"$m\""))
    }

    @Test("a launch flags its session as remote until the marker names the machine")
    func expectedSession() {
        AppServices.expectRemoteSession("repo-card_expected")
        #expect(AppServices.isRemoteSessionExpected("repo-card_expected"))
        AppServices.markRemoteSessionReady("repo-card_expected", machine: "kanban-repo-2")
        #expect(!AppServices.isRemoteSessionExpected("repo-card_expected"))
        let content = try? String(contentsOfFile: AppServices.remoteReadyMarkerPath(for: "repo-card_expected"), encoding: .utf8)
        #expect(content == "kanban-repo-2")
        AppServices.clearRemoteSessionReady("repo-card_expected")
    }

    @Test("the ready marker lives under the kanban home, named after the session")
    func markerPath() {
        let path = AppServices.remoteReadyMarkerPath(for: "repo-card_1")
        #expect(path.hasSuffix("/.kanban-code/remote-ready/repo-card_1"))
        AppServices.markRemoteSessionReady("repo-card_test-marker")
        #expect(FileManager.default.fileExists(atPath: AppServices.remoteReadyMarkerPath(for: "repo-card_test-marker")))
        AppServices.clearRemoteSessionReady("repo-card_test-marker")
        #expect(!FileManager.default.fileExists(atPath: AppServices.remoteReadyMarkerPath(for: "repo-card_test-marker")))
    }
}
