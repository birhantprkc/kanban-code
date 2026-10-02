import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit

extension Notification.Name {
    /// Shows the detail sheet of an attention request; userInfo["id"].
    static let kanbanCodeShowAttention = Notification.Name("kanbanCodeShowAttention")
}

/// Presents the detail sheet of the attention request a notification click
/// or the attention center names, over the board. Requests arriving while a
/// sheet is up wait in line, one sheet at a time.
struct AttentionDetailPresenter: ViewModifier {
    let store: BoardStore
    @State private var shownId: String?
    @State private var waiting: [String] = []

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeShowAttention).receive(on: RunLoop.main)) { note in
                guard let id = note.userInfo?["id"] as? String, store.state.attentionRequests[id] != nil else { return }
                if shownId == nil {
                    shownId = id
                } else {
                    waiting = AttentionSheetQueue.adding(id, to: waiting, shown: shownId)
                }
            }
            .onChange(of: shownId) {
                guard shownId == nil, !waiting.isEmpty else { return }
                Task { @MainActor in
                    // Lets the closing sheet finish before the next one opens.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard shownId == nil else { return }
                    shownId = AttentionSheetQueue.popNext(&waiting) { store.state.attentionRequests[$0]?.isOpen == true }
                }
            }
            .sheet(item: Binding(
                get: { shownId.map(AttentionSheetTarget.init) },
                set: { shownId = $0?.id }
            )) { target in
                if let request = store.state.attentionRequests[target.id] {
                    AttentionDetailSheet(
                        request: request,
                        cardName: request.cardId.flatMap { id in store.state.cards.first { $0.id == id }?.displayTitle },
                        onClose: { shownId = nil }
                    )
                }
            }
    }
}

private struct AttentionSheetTarget: Identifiable {
    let id: String
}

/// Everything about one attention request, with its answers: for a vault
/// request the card, the secrets, the command, why the vault asks and the
/// lease it would grant.
struct AttentionDetailSheet: View {
    let request: AttentionRequest
    let cardName: String?
    let onClose: () -> Void
    @State private var busy: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: request.kind == .vaultApproval ? "key.fill" : "bell.badge")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(AttentionCopy.notification(for: request, cardName: cardName).title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(rows, id: \.self) { row in
                        GridRow {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(row.value)
                                .font(row.monospaced ? .system(.body, design: .monospaced) : .body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 380)

            if let resolvedBy = request.resolvedBy, !request.isOpen {
                Label("Answered\(request.resolution.map { ": \($0)" } ?? "") (by \(resolvedBy))", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if request.isOpen {
                    ForEach(Array(request.options.reversed()), id: \.self) { option in
                        Button {
                            answer(option)
                        } label: {
                            HStack(spacing: 4) {
                                if busy == option { ProgressView().controlSize(.small) }
                                Text(option)
                            }
                        }
                        .disabled(busy != nil)
                        .tint(Self.isNegative(option) ? .red : nil)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var rows: [VaultApprovalDetails.Row] {
        if let vault = request.vault { return vault.rows(cardName: cardName) }
        var rows: [VaultApprovalDetails.Row] = []
        if let cardName { rows.append(.init("Card", cardName)) }
        if !request.body.isEmpty { rows.append(.init(request.title, request.body)) }
        return rows
    }

    private func answer(_ option: String) {
        busy = option
        let id = request.id
        let biometry = request.requiresBiometry
        let title = request.title
        Task { @MainActor in
            defer { busy = nil }
            if biometry, !(await AppDelegate.confirmWithBiometry(reason: "\(option): \(title)")) { return }
            await AppServices.resolveAttention?(id, option)
            onClose()
        }
    }

    static func isNegative(_ option: String) -> Bool {
        let lower = option.lowercased()
        return lower.hasPrefix("deny") || lower.hasPrefix("no")
    }
}
