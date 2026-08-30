import AppKit
import KanbanCodeCore

/// The service graph of the app, built once and shared by every
/// `ContentView` value SwiftUI creates. The store, the boxd supervisor and
/// the remote session registry hold references to each other, so a second
/// copy would send its actions to a store nothing renders.
@MainActor
final class AppComposition {
    static var shared: AppComposition {
        if let current { return current }
        let built = AppComposition()
        current = built
        return built
    }
    private static var current: AppComposition?

    let store: BoardStore
    let orchestrator: BackgroundOrchestrator
    let settingsStore: SettingsStore
    let assistantRegistry: CodingAssistantRegistry
    let launcher: LaunchSession
    let tmuxAdapter: RoutingTmuxAdapter
    let boxdSupervisor: BoxdMachineSupervisor

    private init() {
        let claudeDiscovery = ClaudeCodeSessionDiscovery()
        let claudeDetector = ClaudeCodeActivityDetector()
        let claudeStore = ClaudeCodeSessionStore()
        let geminiDiscovery = GeminiSessionDiscovery()
        let geminiDetector = GeminiActivityDetector()
        let geminiStore = GeminiSessionStore()
        let codexDiscovery = CodexSessionDiscovery()
        let codexDetector = CodexActivityDetector()
        let codexStore = CodexSessionStore()

        let enabledAssistants = ContentView.loadEnabledAssistants()
        let registry = CodingAssistantRegistry()
        if enabledAssistants.contains(.claude) {
            registry.register(.claude, discovery: claudeDiscovery, detector: claudeDetector, store: claudeStore)
        }
        if enabledAssistants.contains(.gemini) {
            registry.register(.gemini, discovery: geminiDiscovery, detector: geminiDetector, store: geminiStore)
        }
        if enabledAssistants.contains(.codex) {
            registry.register(.codex, discovery: codexDiscovery, detector: codexDetector, store: codexStore)
        }

        let discovery = CompositeSessionDiscovery(registry: registry)
        let activityDetector = CompositeActivityDetector(registry: registry, defaultDetector: claudeDetector)

        let coordination = CoordinationStore()
        let settings = SettingsStore()
        let remoteRegistry = RemoteSessionRegistry()
        let tmux = RoutingTmuxAdapter(local: TmuxAdapter(), registry: remoteRegistry)
        let supervisor = BoxdMachineSupervisor(
            boxd: BoxdCliAdapter(),
            registry: remoteRegistry,
            settingsProvider: { (try? await settings.read())?.boxd ?? BoxdSettings() },
            cliBundlePath: AppServices.cliBundlePath,
            appVersion: AppServices.appVersion
        )
        AppServices.tmux = tmux
        AppServices.remoteRegistry = remoteRegistry
        AppServices.boxdSupervisor = supervisor

        let effectHandler = EffectHandler(
            coordinationStore: coordination,
            tmuxAdapter: tmux,
            setClipboardImage: { data in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            },
            notifier: MacOSNotificationClient(),
            remoteMachines: supervisor
        )

        let boardStore = BoardStore(
            effectHandler: effectHandler,
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            settingsStore: settings,
            ghAdapter: GhCliAdapter(),
            worktreeAdapter: GitWorktreeAdapter(),
            tmuxAdapter: tmux
        )

        // Load Pushover from settings.json, wrap in CompositeNotifier with macOS fallback
        let (pushover, pushoverMode) = ContentView.loadPushoverConfig()
        let notifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient(), pushoverMode: pushoverMode)

        let orch = BackgroundOrchestrator(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            tmux: tmux,
            prTracker: GhCliAdapter(),
            notifier: notifier,
            registry: registry
        )

        let launch = LaunchSession(tmux: tmux)

        orch.setDispatch { [weak boardStore] action in
            boardStore?.dispatch(action)
        }
        AppServices.pauseMachine = { [weak boardStore] cardId in
            boardStore?.dispatch(.pauseRemoteMachine(cardId: cardId, reason: .manual))
        }
        AppServices.destroyMachine = { [weak boardStore] cardId in
            boardStore?.dispatch(.showDialog(.confirmDestroyMachine(cardId: cardId)))
        }
        Task { [weak boardStore] in
            await supervisor.setDispatch { action in
                boardStore?.dispatch(action)
            }
            await supervisor.setProxyRunner { invocation in
                await AppServices.runProxiedCommand(invocation)
            }
            await supervisor.setBusyCheck { machineName in
                await MainActor.run {
                    guard let boardStore else { return false }
                    let state = boardStore.state
                    return state.cardIds(onMachine: machineName).contains { cardId in
                        guard let sessionId = state.links[cardId]?.sessionLink?.sessionId else { return false }
                        return state.activityMap[sessionId] == .activelyWorking
                    }
                }
            }
            await supervisor.setLinksProvider {
                await MainActor.run { boardStore.map { Array($0.state.links.values) } ?? [] }
            }
        }


        // Restore persisted detail expansion and card selection before first render
        // to avoid flicker. @AppStorage values are available synchronously.
        let persistedExpanded = UserDefaults.standard.bool(forKey: "detailExpanded")
        let persistedCardId = UserDefaults.standard.string(forKey: "selectedCardId") ?? ""
        if persistedExpanded {
            boardStore.dispatch(.setDetailExpanded(true))
        }
        if !persistedCardId.isEmpty {
            boardStore.dispatch(.selectCard(cardId: persistedCardId))
        }

        self.store = boardStore
        self.orchestrator = orch
        self.settingsStore = settings
        self.assistantRegistry = registry
        self.launcher = launch
        self.tmuxAdapter = tmux
        self.boxdSupervisor = supervisor
        KanbanCodeLog.info("app", "services composed")
    }
}
