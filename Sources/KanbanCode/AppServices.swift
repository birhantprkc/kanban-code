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

    /// True when at least one boxd machine has an open bridge.
    static var hasConnectedMachines: Bool {
        remoteRegistry?.states.values.contains { $0.isConnected } ?? false
    }

    /// Machine that hosts a tmux session, when it is remote.
    static func machine(forSession sessionName: String) -> String? {
        remoteRegistry?.machine(forSession: sessionName)
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
