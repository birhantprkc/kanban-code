import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit

/// The service graph and loops of a headless master: the same BoardStore the
/// Mac app drives, over the kanban home of this machine, plus peer sync.
/// Launching and the hook-driven orchestration join it with the master engine.
@MainActor
final class ServerMaster {
    let home: String
    let store: BoardStore
    let settingsStore: SettingsStore
    let identity: MachineIdentity
    let peerSync: PeerSync
    let reconciles: Bool

    init(home: String, reconciles: Bool) {
        self.home = home
        self.reconciles = reconciles

        let settingsStore = SettingsStore(basePath: home)
        let settings = Self.readSettings(home: home).settings
        let enabled = settings?.enabledAssistants ?? CodingAssistant.allCases

        let registry = CodingAssistantRegistry()
        let claudeDetector = ClaudeCodeActivityDetector()
        if enabled.contains(.claude) {
            registry.register(.claude, discovery: ClaudeCodeSessionDiscovery(), detector: claudeDetector, store: ClaudeCodeSessionStore())
        }
        if enabled.contains(.gemini) {
            registry.register(.gemini, discovery: GeminiSessionDiscovery(), detector: GeminiActivityDetector(), store: GeminiSessionStore())
        }
        if enabled.contains(.codex) {
            registry.register(.codex, discovery: CodexSessionDiscovery(), detector: CodexActivityDetector(), store: CodexSessionStore())
        }

        let coordination = CoordinationStore(basePath: home)
        let tmux = TmuxAdapter()
        let effectHandler = EffectHandler(
            coordinationStore: coordination,
            tmuxAdapter: tmux,
            notifier: MacOSNotificationClient()
        )
        let store = BoardStore(
            effectHandler: effectHandler,
            discovery: CompositeSessionDiscovery(registry: registry),
            coordinationStore: coordination,
            activityDetector: CompositeActivityDetector(registry: registry, defaultDetector: claudeDetector),
            settingsStore: settingsStore,
            ghAdapter: GhCliAdapter(),
            worktreeAdapter: GitWorktreeAdapter(),
            tmuxAdapter: tmux
        )
        self.store = store
        self.settingsStore = settingsStore

        identity = MachineIdentityStore(basePath: home).loadOrCreate()
        peerSync = PeerSync(identity: identity, peers: settings?.peers ?? []) { [weak store] action in
            await MainActor.run { store?.dispatch(action) }
        }
    }

    /// Loads the board, then runs the loops until the task is cancelled.
    func start() async {
        store.dispatch(.localMachineLoaded(identity))
        await store.loadSettingsAndCache()
        if reconciles { await store.reconcile() }

        let peerSync = self.peerSync
        Task.detached { await peerSync.run() }
        Task { await self.settingsLoop() }
        if reconciles {
            Task { await self.reconcileLoop() }
        }
    }

    private func reconcileLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            await store.reconcile()
        }
    }

    /// Picks up settings edits (projects, peers) without a restart.
    private func settingsLoop() async {
        var last = Self.readSettings(home: home)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            let current = Self.readSettings(home: home)
            guard current.raw != last.raw, let settings = current.settings else { continue }
            if settings.peers != last.settings?.peers { await peerSync.setPeers(settings.peers) }
            last = current
            await store.loadSettingsAndCache()
        }
    }

    nonisolated static func readSettings(home: String) -> (raw: Data?, settings: Settings?) {
        let path = (home as NSString).appendingPathComponent("settings.json")
        guard let data = FileManager.default.contents(atPath: path) else { return (nil, nil) }
        return (data, try? JSONDecoder().decode(Settings.self, from: data))
    }
}
