import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit
import Observation

/// The remote control host of a headless master, over its BoardStore: the
/// board, transcripts and terminals. Launching, prompting and interrupting
/// come with the master engine; until then those calls answer 409.
final class ServerHost: RemoteControlHost {
    let store: BoardStore
    private let tmux = TmuxAdapter()

    init(store: BoardStore) {
        self.store = store
    }

    @MainActor
    private func card(_ cardId: String) throws -> KanbanCodeCard {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else {
            throw RemoteHostError.notFound("no card \(cardId)")
        }
        return card
    }

    private static func notYet(_ what: String) -> RemoteHostError {
        .conflict("\(what) is not available on this host yet")
    }

    // MARK: - RemoteControlHost

    func board() async -> RemoteBoard {
        await MainActor.run {
            RemoteBoardMapper.board(
                cards: store.state.cards,
                projects: store.state.configuredProjects,
                liveSessions: store.state.tmuxSessions,
                agtopQueues: store.state.agtopQueues
            )
        }
    }

    func transcript(cardId: String, limit: Int, before: String?) async throws -> RemoteTranscript {
        let (path, assistant) = try await MainActor.run { () throws -> (String?, CodingAssistant) in
            let card = try card(cardId)
            return (card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath, card.link.effectiveAssistant)
        }
        guard let path, FileManager.default.fileExists(atPath: path) else {
            return RemoteTranscript(cardId: cardId, messages: [])
        }
        return try await RemoteTranscriptMapper.page(cardId: cardId, limit: limit, before: before) { maxTurns in
            switch assistant {
            case .claude:
                let r = try await TranscriptReader.readTail(from: path, maxTurns: maxTurns)
                return (r.turns, r.hasMore)
            case .codex:
                let r = try await CodexSessionParser.readTail(from: path, maxTurns: maxTurns)
                return (r.turns, r.hasMore)
            default:
                let all = try await GeminiSessionStore().readTranscript(sessionPath: path)
                return (Array(all.suffix(maxTurns)), all.count > maxTurns)
            }
        }
    }

    func createTask(_ request: RemoteTaskRequest) async throws -> RemoteCard {
        throw Self.notYet("creating tasks")
    }

    func sendPrompt(cardId: String, _ request: RemotePromptRequest, images: [RemotePromptImages.Decoded]) async throws {
        _ = try await MainActor.run { try card(cardId) }
        throw Self.notYet("sending prompts")
    }

    func sendQueuedPromptNow(cardId: String, promptId: String) async throws {
        throw Self.notYet("queued prompts")
    }

    func removeQueuedPrompt(cardId: String, promptId: String) async throws {
        throw Self.notYet("queued prompts")
    }

    func interrupt(cardId: String) async throws {
        _ = try await MainActor.run { try card(cardId) }
        throw Self.notYet("interrupting")
    }

    func resume(cardId: String) async throws -> RemoteCard {
        _ = try await MainActor.run { try card(cardId) }
        throw Self.notYet("resuming")
    }

    func terminalCommand(cardId: String, sessionName: String) async throws -> [String] {
        try await MainActor.run { () throws -> [String] in
            let card = try card(cardId)
            guard (card.link.tmuxLink?.allSessionNames ?? []).contains(sessionName) else {
                throw RemoteHostError.notFound("card \(cardId) has no terminal \(sessionName)")
            }
            guard store.state.tmuxSessions.contains(sessionName) else {
                throw RemoteHostError.conflict("terminal \(sessionName) is not running; resume the card first")
            }
            if let agtopId = AgtopSessionName.agtopId(fromName: sessionName) {
                return [AgtopCliAdapter.findExecutable() ?? "agtop", "open", agtopId, "--solo"]
            }
            return [ShellCommand.findExecutable("tmux") ?? "tmux", "attach-session", "-t", sessionName]
        }
    }

    func scrollTerminal(sessionName: String, lines: Int) async {
        guard !AgtopSessionName.isAgtop(sessionName) else { return }
        for command in RemoteTerminalScroll.tmuxCommands(session: sessionName, lines: lines) {
            _ = try? await tmux.run(command)
        }
    }

    func boardChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let store = self.store
        let alive = AliveFlag()
        continuation.onTermination = { _ in alive.stop() }
        Task { @MainActor in
            Self.observe(store: store, continuation: continuation, alive: alive)
        }
        return stream
    }

    /// Yields once per change of the cards, the live sessions or the
    /// projects, re-arming the observation each time.
    @MainActor
    private static func observe(store: BoardStore, continuation: AsyncStream<Void>.Continuation, alive: AliveFlag) {
        guard alive.isAlive else { return }
        withObservationTracking {
            _ = store.state.cards
            _ = store.state.tmuxSessions
            _ = store.state.agtopQueues
            _ = store.state.configuredProjects
        } onChange: {
            continuation.yield()
            Task { @MainActor in observe(store: store, continuation: continuation, alive: alive) }
        }
    }
}

/// Set until the board change stream ends.
final class AliveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true

    var isAlive: Bool { lock.withLock { alive } }

    func stop() { lock.withLock { alive = false } }
}
