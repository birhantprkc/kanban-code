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
        let attachIndex = script.range(of: "KANBAN_MACHINE=\"$m\" /usr/bin/expect -c '")
        #expect(script.contains("machine connect $env(KANBAN_MACHINE)"))
        #expect(script.contains("send \" exec tmux -u -T hyperlinks attach-session -t repo-card_1\\r\""))
        #expect(script.contains("m=\"$(cat '/Users/me/.kanban-code/remote-ready/repo-card_1' 2>/dev/null)\"; [ -n \"$m\" ] || m='kanban-repo-1'"))
        #expect(waitIndex != nil)
        #expect(attachIndex != nil)
        if let waitIndex, let attachIndex {
            #expect(waitIndex.lowerBound < attachIndex.lowerBound)
        }
        #expect(script.hasSuffix("echo 'Session ended.'"))
    }

    @Test("a pause by the app holds the retries until the pause marker goes away")
    func pausedMarker() {
        let script = TerminalCache.remoteAttachScript(
            boxd: "boxd", machine: "kanban-repo-1", session: "s", readyMarker: "/tmp/marker")
        // The pause marker is read before the connect, because a connect
        // that succeeds wakes the machine and leaves the loop for good.
        #expect(script.contains("while [ $n -lt 30 ]; do if [ -e '/tmp/marker.paused' ]; then echo 'Machine paused. Click here to bring it back.'; while [ -e '/tmp/marker.paused' ]; do sleep 1; done; n=0; fi; "))
        // The machine is read from the marker on every try.
        #expect(script.contains("m=\"$(cat '/tmp/marker' 2>/dev/null)\"; [ -n \"$m\" ] || m='kanban-repo-1'; KANBAN_MACHINE=\"$m\" /usr/bin/expect -c '"))
        #expect(script.contains("' && break; if [ -e '/tmp/marker.paused' ]; then continue; fi; n=$((n+1)); sleep 2; done; echo 'Session ended.'"))
        #expect(TerminalCache.pausedMarkerSuffix == ".paused")
        let pauseCheck = script.range(of: "if [ -e '/tmp/marker.paused' ]")
        let firstAttach = script.range(of: "KANBAN_MACHINE=\"$m\" /usr/bin/expect")
        #expect(pauseCheck != nil && firstAttach != nil)
        if let pauseCheck, let firstAttach {
            #expect(pauseCheck.lowerBound < firstAttach.lowerBound)
        }
    }

    @Test("wheel ticks on a machine become one copy-mode move per flush")
    func remoteScrollCommands() {
        #expect(TerminalCache.remoteScrollCommands(session: "s", enter: true, delta: 5) == [
            ["copy-mode", "-t", "s"],
            ["send-keys", "-t", "s", "-X", "-N", "5", "cursor-up"],
        ])
        #expect(TerminalCache.remoteScrollCommands(session: "s", enter: false, delta: -3) == [
            ["send-keys", "-t", "s", "-X", "-N", "3", "cursor-down"],
        ])
        // Ticks that cancel out send nothing.
        #expect(TerminalCache.remoteScrollCommands(session: "s", enter: false, delta: 0).isEmpty)
    }

    @Test("without a marker the attach is retried right away")
    func noMarker() {
        let script = TerminalCache.remoteAttachScript(boxd: "boxd", machine: "kanban-repo-1", session: "s")
        #expect(!script.contains("remote-ready"))
        #expect(script.hasPrefix("m='kanban-repo-1'; for i in $(seq 1 30); do KANBAN_MACHINE=\"$m\" /usr/bin/expect -c '"))
    }

    @Test("expect waits for the prompt, types the attach, and hands the pty over")
    func expectProgram() {
        let program = TerminalCache.expectProgram(boxd: "/opt/boxd", session: "repo-card_1")
        let steps = program.components(separatedBy: "; ")
        #expect(steps[0] == "set timeout 20")
        #expect(steps[1] == "spawn -noecho {/opt/boxd} machine connect $env(KANBAN_MACHINE)")
        #expect(steps[2] == "trap {stty rows [stty rows] columns [stty columns] < $spawn_out(slave,name)} WINCH")
        #expect(steps[3] == "expect -re {\\$ $} {send \" exec tmux -u -T hyperlinks attach-session -t repo-card_1\\r\"} timeout {send \" exec tmux -u -T hyperlinks attach-session -t repo-card_1\\r\"} eof {exit 1}")
        #expect(steps[4] == "interact")
        #expect(steps[5] == "catch wait result")
        #expect(steps[6] == "exit [lindex $result 3]")
    }

    @Test("the attach retries when connect fails and stops when it ends cleanly")
    func retryLoop() {
        let script = TerminalCache.remoteAttachScript(boxd: "boxd", machine: "kanban-repo-1", session: "s")
        #expect(script.contains("/usr/bin/expect -c 'set timeout 20; spawn -noecho {boxd} machine connect $env(KANBAN_MACHINE); "))
        #expect(script.hasSuffix("' && break; sleep 2; done; echo 'Session ended.'"))
    }

    @Test("a terminal that starts before the machine is known takes the machine from the marker")
    func machineFromMarker() {
        let script = TerminalCache.remoteAttachScript(
            boxd: "boxd", machine: nil, session: "s", readyMarker: "/tmp/marker")
        #expect(script.contains("m=\"$(cat '/tmp/marker' 2>/dev/null)\"; [ -n \"$m\" ] || m=''"))
        #expect(script.contains("KANBAN_MACHINE=\"$m\" /usr/bin/expect -c"))
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
