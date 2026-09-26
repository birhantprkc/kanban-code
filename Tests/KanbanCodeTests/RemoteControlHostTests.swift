import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCode

private final class SentPrompts: TmuxManagerPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(session: String, text: String)] = []
    private var _escapes: [String] = []

    var sent: [(session: String, text: String)] { lock.withLock { _sent } }
    var escapes: [String] { lock.withLock { _escapes } }
    func escape(_ session: String) { lock.withLock { _escapes.append(session) } }
    private func record(_ session: String, _ text: String) { lock.withLock { _sent.append((session, text)) } }

    func listSessions() async throws -> [TmuxSession] { [] }
    func createSession(name: String, path: String, command: String?) async throws {}
    func killSession(name: String) async throws {}
    func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
    func sendPrompt(to sessionName: String, text: String) async throws { record(sessionName, text) }
    func pastePrompt(to sessionName: String, text: String) async throws { record(sessionName, text) }
    func pasteText(to sessionName: String, text: String) async throws {}
    func submitPrompt(to sessionName: String) async throws {}
    func capturePane(sessionName: String) async throws -> String { "" }
    func sendBracketedPaste(to sessionName: String) async throws {}
    func isAvailable() async -> Bool { true }
}

/// The app's remote control host over a real store: prompts, interrupts and
/// terminals go through the same actions and commands as the UI.
@Suite("Remote control host")
@MainActor
struct RemoteControlHostTests {
    private func makeHost() -> (AppRemoteControlHost, BoardStore, SentPrompts) {
        let tmux = SentPrompts()
        let dir = NSTemporaryDirectory() + "kanban-remote-host-\(UUID().uuidString)"
        let store = BoardStore(
            effectHandler: EffectHandler(
                coordinationStore: CoordinationStore(basePath: dir),
                tmuxAdapter: tmux,
                queuedPromptJournal: QueuedPromptJournal(basePath: dir)
            ),
            discovery: ClaudeCodeSessionDiscovery(),
            coordinationStore: CoordinationStore(basePath: dir)
        )
        let host = AppRemoteControlHost(store: store) { session in tmux.escape(session) }
        return (host, store, tmux)
    }

    private func addCard(_ store: BoardStore, id: String, session: String, live: Bool, busy: Bool) {
        let link = Link(
            id: id, name: "Card \(id)", projectPath: "/tmp/acme", column: .inProgress,
            sessionLink: SessionLink(sessionId: "sid-\(id)"), tmuxLink: TmuxLink(sessionName: session)
        )
        store.dispatch(.createManualTask(link))
        store.dispatch(.tmuxLivenessScanned(live: live ? store.state.tmuxSessions.union([session]) : store.state.tmuxSessions))
        if busy { store.dispatch(.activityChanged(["sid-\(id)": .activelyWorking])) }
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<50 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("the board lists the store's cards")
    func board() async {
        let (host, store, _) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: false)
        let board = await host.board()
        let card = board.cards.first { $0.id == "card_a" }
        #expect(card?.isLive == true)
        #expect(card?.runtime == .tmux)
    }

    @Test("a prompt to an idle card goes out at once")
    func promptIdle() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: false)
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "hello", mode: .queue))
        await waitFor { !tmux.sent.isEmpty }
        #expect(tmux.sent.map(\.text) == ["hello"])
        #expect(store.state.links["card_a"]?.queuedPrompts == nil)
    }

    @Test("a queued prompt to a busy card waits in the card's queue")
    func promptBusy() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: true)
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "after this", mode: .queue))
        #expect(store.state.links["card_a"]?.queuedPrompts?.map(\.body) == ["after this"])
        #expect(store.state.links["card_a"]?.queuedPrompts?.first?.sendAutomatically == true)
        #expect(tmux.sent.isEmpty)
    }

    @Test("mode now interrupts a busy card, then sends")
    func promptNow() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: true)
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "stop, wrong file", mode: .now))
        await waitFor { !tmux.sent.isEmpty }
        #expect(tmux.escapes == ["card-a"])
        #expect(tmux.sent.map(\.text) == ["stop, wrong file"])
    }

    @Test("a card without a live session refuses prompts and interrupts with 409")
    func notLive() async {
        let (host, store, _) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: false, busy: false)
        await #expect(throws: RemoteHostError.conflict("card card_a has no live session; resume it first")) {
            try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "x"))
        }
        await #expect(throws: RemoteHostError.self) { try await host.interrupt(cardId: "card_a") }
        await #expect(throws: RemoteHostError.notFound("no card nope")) {
            try await host.interrupt(cardId: "nope")
        }
    }

    @Test("interrupt sends Esc to the live session")
    func interrupt() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: true)
        try await host.interrupt(cardId: "card_a")
        #expect(tmux.escapes == ["card-a"])
    }

    @Test("terminals: agtop opens its own UI, tmux attaches, unknown sessions are refused")
    func terminals() async throws {
        let (host, store, _) = makeHost()
        addCard(store, id: "card_a", session: "agtop-0123abcd", live: true, busy: false)
        addCard(store, id: "card_b", session: "card-b", live: true, busy: false)
        let agtop = try await host.terminalCommand(cardId: "card_a", sessionName: "agtop-0123abcd")
        #expect(Array(agtop.suffix(3)) == ["open", "0123abcd", "--solo"])
        let tmux = try await host.terminalCommand(cardId: "card_b", sessionName: "card-b")
        #expect(tmux.last?.contains("attach-session -t 'card-b'") == true)
        await #expect(throws: RemoteHostError.self) {
            _ = try await host.terminalCommand(cardId: "card_b", sessionName: "card-a")
        }
    }

    @Test("board changes yield when the store's cards change")
    func changes() async throws {
        let (host, store, _) = makeHost()
        let stream = host.boardChanges()
        try await Task.sleep(for: .milliseconds(50))
        let got = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        addCard(store, id: "card_a", session: "card-a", live: true, busy: false)
        let result = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await got.value }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(result)
    }
}
