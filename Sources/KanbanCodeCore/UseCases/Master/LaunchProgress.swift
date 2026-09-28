import Foundation

/// Reports the steps of a launch or resume to the board and keeps the launch
/// alive while a long step runs.
///
/// A remote launch can take minutes (machine creation, a repository checkout,
/// file copies). The stale-launch timers (the reconciler and the card detail)
/// give up after 30 seconds of silence, so every step is reported as it
/// starts and the last one is repeated every 10 seconds until `finish()`.
@MainActor
public final class LaunchProgress {
    private let cardId: String
    private weak var store: BoardStore?
    private var lastMessage: String?
    private var heartbeat: Task<Void, Never>?

    public init(cardId: String, store: BoardStore) {
        self.cardId = cardId
        self.store = store
    }

    /// Starts the heartbeat. Idempotent.
    public func start() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, let message = self.lastMessage else { continue }
                self.store?.dispatch(.launchProgress(cardId: self.cardId, message: message))
            }
        }
    }

    /// Shows `line` under the spinner and logs it.
    public nonisolated func report(_ line: String) {
        Task { @MainActor [self] in
            KanbanCodeLog.info("boxd", "\(cardId.prefix(12)): \(line)")
            lastMessage = line
            store?.dispatch(.launchProgress(cardId: cardId, message: line))
        }
    }

    public func finish() {
        heartbeat?.cancel()
        heartbeat = nil
    }
}
