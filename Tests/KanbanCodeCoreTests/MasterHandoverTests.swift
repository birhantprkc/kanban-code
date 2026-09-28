import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

/// Records the tmux sessions a master starts instead of running them.
private final class RecordingTmux: TmuxManagerPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _created: [(name: String, command: String?)] = []
    private var _killed: [String] = []
    var created: [(name: String, command: String?)] { lock.withLock { _created } }
    var killed: [String] { lock.withLock { _killed } }

    func listSessions() async throws -> [TmuxSession] { [] }
    func createSession(name: String, path: String, command: String?) async throws {
        lock.withLock { _created.append((name, command)) }
    }
    func killSession(name: String) async throws { lock.withLock { _killed.append(name) } }
    func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
    func sendPrompt(to sessionName: String, text: String) async throws {}
    func pastePrompt(to sessionName: String, text: String) async throws {}
    func pasteText(to sessionName: String, text: String) async throws {}
    func submitPrompt(to sessionName: String) async throws {}
    func capturePane(sessionName: String) async throws -> String { "" }
    func sendBracketedPaste(to sessionName: String) async throws {}
    func isAvailable() async -> Bool { true }
}

/// One master: a board, an engine and its remote control server over a
/// temporary kanban home, with sessions recorded, not run.
@MainActor
private final class TestMaster {
    let home: String
    let identity: MachineIdentity
    let store: BoardStore
    let engine: MasterEngine
    let tmux = RecordingTmux()
    let devices: RemoteDeviceStore
    var server: RemoteControlServer!
    var peerSync: PeerSync!
    /// A token this master issued, for the other one.
    var tokenForPeer = ""

    init(name: String, root: String) throws {
        home = "\(root)/\(name)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        identity = MachineIdentity(name: name)
        let coordination = CoordinationStore(basePath: home)
        store = BoardStore(
            effectHandler: EffectHandler(
                coordinationStore: coordination, tmuxAdapter: tmux,
                queuedPromptJournal: QueuedPromptJournal(basePath: home)),
            discovery: ClaudeCodeSessionDiscovery(),
            coordinationStore: coordination
        )
        var platform = MasterPlatform()
        platform.projectsDirectory = "\(home)/Projects"
        platform.claudeProjectsDirectory = "\(home)/claude-projects"
        engine = MasterEngine(
            store: store,
            settingsStore: SettingsStore(basePath: home),
            launcher: LaunchSession(tmux: tmux),
            tmux: RoutingTmuxAdapter(agtop: AgtopCliAdapter(executable: "/nonexistent/agtop")),
            registry: CodingAssistantRegistry(),
            platform: platform
        )
        store.dispatch(.localMachineLoaded(identity))
        devices = RemoteDeviceStore(path: "\(home)/devices.json")
        tokenForPeer = try devices.add(name: "peer", scope: .full).token
    }

    func start(peerURL: String, peerToken: String) async throws {
        let store = self.store
        peerSync = PeerSync(identity: identity, peers: [PeerConfig(name: "peer", url: peerURL, token: peerToken)]) { action in
            await MainActor.run { store.dispatch(action) }
        }
        engine.peerSync = peerSync
        engine.installForeignCardHandler()
    }

    func serve() async throws {
        server = RemoteControlServer(
            host: MasterRemoteControlHost(engine: engine), devices: devices, port: 0,
            bindAddresses: { [RemoteNetworkAddresses.loopback] },
            options: .init(appVersion: "test", hostName: identity.name),
            peerServer: BoardPeerLinksServer(store: store, peerSync: nil)
        )
        try await server.start()
    }

    var url: String { "http://127.0.0.1:\(server.port)" }
}

@discardableResult
private func sh(_ args: [String], in dir: String) async throws -> String {
    let result = try await ShellCommand.run("/usr/bin/env", arguments: args, currentDirectory: dir, timeout: 60)
    #expect(result.exitCode == 0, "\(args.joined(separator: " ")): \(result.stderr)")
    return result.stdout
}

private struct FixedDiscovery: SessionDiscovery {
    let sessions: [Session]
    func discoverSessions() async throws -> [Session] { sessions }
    func discoverNewOrModified(since: Date) async throws -> [Session] { sessions }
}

@Suite("Master handover between peers", .serialized)
@MainActor
struct MasterHandoverTests {
    @Test("repository URLs compare across ssh and https forms")
    func repoURLs() {
        #expect(MasterEngine.normalizedRepoURL("git@github.com:ACME/Widgets.git") == "github.com/acme/widgets")
        #expect(MasterEngine.normalizedRepoURL("https://github.com/acme/widgets") == "github.com/acme/widgets")
        #expect(MasterEngine.normalizedRepoURL("ssh://git@github.com/acme/widgets.git/") == "github.com/acme/widgets")
        #expect(MasterEngine.repoName(of: "git@github.com:acme/widgets.git") == "widgets")
        #expect(MasterEngine.repoName(of: "/tmp/origin/widgets.git") == "widgets")
    }

    @Test("a card moves to a peer: session ends, branch and changes follow, the peer adopts and resumes")
    func handover() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("handover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let origin = "\(root)/origin/widgets.git"
        let repoA = "\(root)/mac/widgets"
        try FileManager.default.createDirectory(atPath: "\(root)/origin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/mac", withIntermediateDirectories: true)
        try await sh(["git", "init", "--bare", "-q", origin], in: root)
        try await sh(["git", "clone", "-q", origin, repoA], in: root)
        try await sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repoA)
        try await sh(["git", "push", "-q", "origin", "HEAD"], in: repoA)
        let worktreeA = "\(repoA)/.claude/worktrees/fix-bug"
        try await sh(["git", "worktree", "add", "-q", "-b", "fix-bug", worktreeA], in: repoA)
        try await sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "work"], in: worktreeA)
        try "not committed yet\n".write(toFile: "\(worktreeA)/notes.txt", atomically: true, encoding: .utf8)

        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        let sessionId = "0f1e2d3c-aaaa-bbbb-cccc-000000000001"
        let transcriptA = mac.engine.transcriptPath(cwd: worktreeA, sessionId: sessionId)
        try FileManager.default.createDirectory(atPath: (transcriptA as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let line = #"{"type":"user","cwd":"\#(worktreeA)","message":{"role":"user","content":"edit \#(worktreeA)/notes.txt"}}"#
        try (line + "\n").write(toFile: transcriptA, atomically: true, encoding: .utf8)
        mac.store.dispatch(.createManualTask(Link(
            id: "card_move", name: "Fix the bug", projectPath: repoA, column: .waiting,
            sessionLink: SessionLink(sessionId: sessionId, sessionPath: transcriptA),
            tmuxLink: TmuxLink(sessionName: "claude-0f1e2d3c"),
            worktreeLink: WorktreeLink(path: worktreeA, branch: "fix-bug")
        )))

        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()
        #expect(box.store.state.links["card_move"]?.ownerMachine == mac.identity.id)
        #expect(mac.engine.isPeerOnline(box.identity.id))

        try await mac.engine.moveCard("card_move", to: "box")
        #expect(mac.tmux.killed.contains("claude-0f1e2d3c") || mac.store.state.links["card_move"]?.tmuxLink != nil)
        #expect(mac.store.state.links["card_move"]?.ownerMachine == box.identity.id)
        #expect(mac.store.state.links["card_move"]?.migrating == true)
        let pushed = try await sh(["git", "branch", "--list", "fix-bug"], in: origin)
        #expect(pushed.contains("fix-bug"))

        await box.peerSync.pullAll()
        let released = try #require(box.store.state.links["card_move"])
        #expect(released.ownerMachine == box.identity.id)
        #expect(released.migrating == true)

        try await box.engine.adopt(cardId: "card_move")
        let adopted = try #require(box.store.state.links["card_move"])
        let repoB = "\(box.home)/Projects/widgets"
        let worktreeB = "\(repoB)/.claude/worktrees/fix-bug"
        #expect(adopted.migrating == nil)
        #expect(adopted.projectPath == repoB)
        #expect(adopted.worktreeLink?.path == worktreeB)
        #expect(FileManager.default.fileExists(atPath: "\(worktreeB)/notes.txt"))
        let log = try await sh(["git", "log", "--format=%s", "-1"], in: worktreeB)
        #expect(log.contains("work"))
        let transcriptB = try #require(adopted.sessionLink?.sessionPath)
        #expect(transcriptB == box.engine.transcriptPath(cwd: worktreeB, sessionId: sessionId))
        let copied = try String(contentsOfFile: transcriptB, encoding: .utf8)
        #expect(copied.contains(worktreeB))
        #expect(!copied.contains(worktreeA))

        // The resume runs on the box.
        for _ in 0..<50 where box.tmux.created.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(box.tmux.created.first?.command?.contains("--resume \(sessionId)") == true)

        // The Mac sees the box as the owner once it pulls.
        await mac.peerSync.pullAll()
        #expect(mac.store.state.links["card_move"]?.ownerMachine == box.identity.id)
        #expect(mac.store.state.links["card_move"]?.migrating == nil)
        #expect(mac.engine.isForeign("card_move"))
    }

    @Test("reconcile leaves a card released to this master alone until it is adopted")
    func migratingIsFrozen() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("frozen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let coordination = CoordinationStore(basePath: dir)
        let store = BoardStore(
            effectHandler: EffectHandler(coordinationStore: coordination, tmuxAdapter: RecordingTmux(),
                                         queuedPromptJournal: QueuedPromptJournal(basePath: dir)),
            discovery: FixedDiscovery(sessions: [Session(id: "sid-1", projectPath: "/box/repo", jsonlPath: "/box/stale.jsonl")]),
            coordinationStore: coordination
        )
        store.dispatch(.localMachineLoaded(MachineIdentity(id: "machine_box", name: "box")))
        var link = Link(id: "card_x", name: "Moving", projectPath: "/mac/repo", column: .waiting,
                        sessionLink: SessionLink(sessionId: "sid-1", sessionPath: "/mac/live.jsonl"))
        link.ownerMachine = "machine_mac"
        link.ownerRev = SyncStamp(counter: 5, machine: "machine_mac")
        store.dispatch(.peerLinksMerged(peer: "machine_mac", links: [link]))
        var release = link
        release.ownerMachine = "machine_box"
        release.migrating = true
        release.ownerRev = SyncStamp(counter: 6, machine: "machine_mac")
        store.dispatch(.peerLinksMerged(peer: "machine_mac", links: [release]))
        #expect(store.state.links["card_x"]?.migrating == true)
        await store.reconcile()
        #expect(store.state.links["card_x"]?.sessionLink?.sessionPath == "/mac/live.jsonl")
        #expect(store.state.links["card_x"]?.ownerRev == SyncStamp(counter: 6, machine: "machine_mac"))
    }

    @Test("a prompt on a card another master owns goes to that master")
    func foreignPrompt() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("foreign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }

        box.store.dispatch(.createManualTask(Link(
            id: "card_box", name: "On the box", projectPath: "/tmp/acme", column: .waiting,
            sessionLink: SessionLink(sessionId: "sid-box"), tmuxLink: TmuxLink(sessionName: "box-session")
        )))
        box.store.dispatch(.tmuxLivenessScanned(live: ["box-session"]))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()
        #expect(mac.engine.isForeign("card_box"))
        #expect(mac.store.state.cards.first { $0.id == "card_box" }?.owner?.name == "box")

        mac.store.dispatch(.addQueuedPrompt(cardId: "card_box", prompt: QueuedPrompt(body: "from the mac"), placement: .back))
        // Nothing queued on the Mac's copy; the box got it and sent it.
        #expect(mac.store.state.links["card_box"]?.queuedPrompts == nil)
        for _ in 0..<60 where box.tmux.created.isEmpty && box.store.state.links["card_box"]?.queuedPrompts == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let boxLink = try #require(box.store.state.links["card_box"])
        // An idle live card sends at once: the prompt went through the box's queue.
        #expect(boxLink.queuedPrompts == nil || boxLink.queuedPrompts?.first?.body == "from the mac")
    }

    @Test("renames, moves and archives from either master converge on both")
    func sharedEditsConverge() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("converge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        box.store.dispatch(.createManualTask(Link(id: "card_c", name: "Start", projectPath: "/tmp/acme", column: .waiting)))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()

        let macClient = RemoteClient(baseURL: URL(string: mac.url)!, token: try mac.devices.add(name: "phone", scope: .full).token)
        let boxClient = RemoteClient(baseURL: URL(string: box.url)!, token: try box.devices.add(name: "phone", scope: .full).token)
        // One after the other: both edits stay.
        _ = try await macClient.updateCard(cardId: "card_c", RemoteCardUpdate(name: "Renamed on the Mac"))
        await box.peerSync.pullAll()
        _ = try await boxClient.updateCard(cardId: "card_c", RemoteCardUpdate(column: .inReview))
        await mac.peerSync.pullAll()
        for master in [mac, box] {
            #expect(master.store.state.links["card_c"]?.name == "Renamed on the Mac")
            #expect(master.store.state.links["card_c"]?.column == .inReview)
        }
        // At the same time: both masters end on the same card.
        _ = try await macClient.updateCard(cardId: "card_c", RemoteCardUpdate(name: "Mac wins?"))
        _ = try await boxClient.updateCard(cardId: "card_c", RemoteCardUpdate(name: "Box wins?"))
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()
        #expect(mac.store.state.links["card_c"]?.name == box.store.state.links["card_c"]?.name)
        _ = try await macClient.updateCard(cardId: "card_c", RemoteCardUpdate(archived: true))
        await box.peerSync.pullAll()
        #expect(box.store.state.links["card_c"]?.manuallyArchived == true)
        #expect(box.store.state.links["card_c"]?.ownerMachine == nil)
    }

    @Test("a first launch on a peer releases the card and the peer starts it")
    func launchOnPeer() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("peer-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let origin = "\(root)/origin/widgets.git"
        let repoA = "\(root)/mac/widgets"
        try FileManager.default.createDirectory(atPath: "\(root)/origin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/mac", withIntermediateDirectories: true)
        try await sh(["git", "init", "--bare", "-q", origin], in: root)
        try await sh(["git", "clone", "-q", origin, repoA], in: root)
        try await sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repoA)
        try await sh(["git", "push", "-q", "origin", "HEAD"], in: repoA)

        let mac = try TestMaster(name: "mac", root: root)
        let box = try TestMaster(name: "box", root: root)
        try await mac.serve()
        try await box.serve()
        try await mac.start(peerURL: box.url, peerToken: box.tokenForPeer)
        try await box.start(peerURL: mac.url, peerToken: mac.tokenForPeer)
        defer { mac.server.stop(); box.server.stop() }
        await mac.peerSync.pullAll()
        await box.peerSync.pullAll()

        mac.store.dispatch(.createManualTask(Link(id: "card_new", name: "New work", projectPath: repoA, column: .backlog, promptBody: "do it")))
        mac.engine.launch(cardId: "card_new", prompt: "do it now", projectPath: repoA, worktreeName: nil,
                          runRemotely: true, machineChoice: .existing("box"))
        #expect(mac.store.state.links["card_new"]?.ownerMachine == box.identity.id)
        #expect(mac.store.state.links["card_new"]?.isLaunching != true)
        #expect(mac.tmux.created.isEmpty)

        await box.peerSync.pullAll()
        try await box.engine.adopt(cardId: "card_new")
        #expect(box.store.state.links["card_new"]?.projectPath == "\(box.home)/Projects/widgets")
        for _ in 0..<50 where box.tmux.created.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(box.tmux.created.count == 1)
    }
}
