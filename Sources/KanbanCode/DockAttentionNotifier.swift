import AppKit
import KanbanCodeCore

/// Mac attention notifications plus the Dock: the icon shows how many
/// requests are posted and bounces until Kanban Code comes to the front
/// when a new one arrives, so a request whose banner closed is still seen.
actor DockAttentionNotifier: MacAttentionNotifier {
    private let inner: any MacAttentionNotifier
    private var posted: Set<String> = []

    init(_ inner: any MacAttentionNotifier) {
        self.inner = inner
    }

    func post(_ request: AttentionRequest, cardName: String?) async {
        await inner.post(request, cardName: cardName)
        let isNew = posted.insert(request.id).inserted
        let count = posted.count
        await MainActor.run {
            NSApp.dockTile.badgeLabel = String(count)
            if isNew, !NSApp.isActive {
                NSApp.requestUserAttention(.criticalRequest)
            }
        }
        KanbanCodeLog.info("attention", "Dock shows \(count) open request(s)\(isNew ? ", bounced for \(request.id)" : "")")
    }

    func remove(id: String) async {
        await inner.remove(id: id)
        guard posted.remove(id) != nil else { return }
        let count = posted.count
        await MainActor.run {
            NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        }
    }
}
