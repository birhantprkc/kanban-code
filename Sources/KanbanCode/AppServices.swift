import Foundation
import KanbanCodeCore

/// Process-wide handles to the adapters the app builds once in
/// `ContentView.init`. Views that are far from the composition root (the
/// embedded terminal, the app delegate, chat views) reach tmux and the boxd
/// supervisor through here instead of building their own adapters.
enum AppServices {
    nonisolated(unsafe) static var tmux = RoutingTmuxAdapter()
    nonisolated(unsafe) static var remoteRegistry: RemoteSessionRegistry?
    nonisolated(unsafe) static var boxdSupervisor: BoxdMachineSupervisor?

    /// Card menu handlers for the boxd machine of a card, set by the
    /// composition root so menus far from the store can reach the reducer.
    nonisolated(unsafe) static var pauseMachine: (@MainActor (String) -> Void)?
    nonisolated(unsafe) static var destroyMachine: (@MainActor (String) -> Void)?

    static var boxdPath: String {
        ShellCommand.findExecutable("boxd") ?? "boxd"
    }

    // MARK: - Remote session readiness

    /// Directory of the marker files that tell the embedded terminal a remote
    /// tmux session exists. The terminal opens as soon as a launch starts,
    /// long before the machine is ready, so it waits for the marker instead
    /// of retrying `tmux attach` against a session that is not there yet.
    static var remoteReadyDirectory: String {
        NSHomeDirectory() + "/.kanban-code/remote-ready"
    }

    static func remoteReadyMarkerPath(for sessionName: String) -> String {
        remoteReadyDirectory + "/" + sessionName
    }

    /// Sessions a launch in flight will create on a machine. The terminal
    /// consults this before the session registry knows the machine, which
    /// happens only once the launch has reached the machine.
    nonisolated(unsafe) private static var expectedRemoteSessions: Set<String> = []
    private static let expectedLock = NSLock()

    /// Writes the marker; its content is the machine name, so a terminal that
    /// started before the machine was known can still attach.
    static func markRemoteSessionReady(_ sessionName: String, machine: String? = nil) {
        try? FileManager.default.createDirectory(atPath: remoteReadyDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: remoteReadyMarkerPath(for: sessionName),
            contents: (machine ?? "").data(using: .utf8)
        )
        try? FileManager.default.removeItem(atPath: remoteReadyMarkerPath(for: sessionName) + BoxdMachineSupervisor.pausedMarkerSuffix)
        expectedLock.lock(); defer { expectedLock.unlock() }
        expectedRemoteSessions.remove(sessionName)
    }

    static func clearRemoteSessionReady(_ sessionName: String) {
        try? FileManager.default.removeItem(atPath: remoteReadyMarkerPath(for: sessionName))
        try? FileManager.default.removeItem(atPath: remoteReadyMarkerPath(for: sessionName) + BoxdMachineSupervisor.pausedMarkerSuffix)
        expectedLock.lock(); defer { expectedLock.unlock() }
        expectedRemoteSessions.remove(sessionName)
    }

    static func expectRemoteSession(_ sessionName: String) {
        expectedLock.lock(); defer { expectedLock.unlock() }
        expectedRemoteSessions.insert(sessionName)
    }

    static func isRemoteSessionExpected(_ sessionName: String) -> Bool {
        expectedLock.lock(); defer { expectedLock.unlock() }
        return expectedRemoteSessions.contains(sessionName)
    }

    /// True when at least one boxd machine has an open bridge.
    static var hasConnectedMachines: Bool {
        remoteRegistry?.states.values.contains { $0.isConnected } ?? false
    }

    /// Machine that hosts a tmux session, when it is remote.
    static func machine(forSession sessionName: String) -> String? {
        remoteRegistry?.machine(forSession: sessionName)
    }

    /// Takes a machine the app holds as paused out of standby, because a
    /// person asked for it. A machine that is not paused is left as it is,
    /// so this costs nothing on the common path.
    @discardableResult
    static func resumeMachineIfPaused(_ machineName: String) -> Bool {
        guard remoteRegistry?.state(of: machineName)?.isPaused == true,
              let supervisor = boxdSupervisor else { return false }
        Task { _ = await supervisor.resume(machineName: machineName) }
        return true
    }

    /// The same, for the machine that hosts a tmux session.
    @discardableResult
    static func resumeMachineIfPaused(forSession sessionName: String) -> Bool {
        guard let machine = machine(forSession: sessionName) else { return false }
        return resumeMachineIfPaused(machine)
    }

    /// Runs the bundled kanban CLI on the Mac for a command proxied from a
    /// machine. `KANBAN_CARD_ID` names the card the command came from.
    static func runProxiedCommand(_ invocation: BoxdProxyInvocation) async -> ShellCommand.Result {
        guard let resourceURL = Bundle.main.resourceURL else {
            return ShellCommand.Result(exitCode: 1, stdout: "", stderr: "kanban CLI bundle not found")
        }
        let cliJS = resourceURL.appendingPathComponent("cli/dist/kanban.js").path
        guard let node = findNode() else {
            return ShellCommand.Result(exitCode: 1, stdout: "", stderr: "node not found on this Mac")
        }
        var argv = invocation.request.argv
        // Image arguments were rewritten on the machine to the proxy image
        // directory; the supervisor wrote them there before this call.
        if !invocation.imagePaths.isEmpty {
            let byName = Dictionary(uniqueKeysWithValues: invocation.imagePaths.map { (($0 as NSString).lastPathComponent, $0) })
            argv = argv.map { argument in
                let name = (argument as NSString).lastPathComponent
                if argument.contains("/images/proxy/"), let local = byName[name] { return local }
                return argument
            }
        }
        var environment = ShellCommand.loginEnvironment
        environment["KANBAN_REMOTE_PROXY"] = nil
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        if let cardId = invocation.cardId { environment["KANBAN_CARD_ID"] = cardId }
        do {
            return try await ShellCommand.run(
                node,
                arguments: [cliJS] + argv,
                currentDirectory: invocation.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil },
                stdin: invocation.request.stdin,
                environment: environment,
                timeout: 110
            )
        } catch {
            return ShellCommand.Result(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }
    }

    static func findNode() -> String? {
        let candidates = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return ShellCommand.findExecutable("node")
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    static var cliBundlePath: String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let path = resourceURL.appendingPathComponent("cli").path
        return FileManager.default.fileExists(atPath: "\(path)/dist/kanban.js") ? path : nil
    }
}
