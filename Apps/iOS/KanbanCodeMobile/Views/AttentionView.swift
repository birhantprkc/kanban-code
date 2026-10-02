import LocalAuthentication
import SwiftUI
import KanbanCodeRemoteKit

/// The decisions agents wait on, across every master, with their answers.
struct AttentionListView: View {
    let fleet: FleetModel
    /// Opens the card of a request on the board.
    var openCard: (String) -> Void = { _ in }
    /// Request the sheet scrolls to, from a notification link.
    var focusId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var busy: String?
    @State private var error: String?
    @State private var freeText: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if fleet.attention.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing waiting on you", systemImage: "checkmark.circle")
                    } description: {
                        Text("Questions, plans and approvals from your agents show here.")
                    }
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(fleet.attention) { item in
                                row(item)
                                    .id(item.id)
                                    .accessibilityIdentifier("attention-\(item.id)")
                            }
                        }
                        .listStyle(.insetGrouped)
                        .onAppear {
                            if let focusId { proxy.scrollTo(focusId, anchor: .top) }
                        }
                    }
                }
            }
            .navigationTitle("Needs you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Could not answer", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    @ViewBuilder
    private func row(_ item: FleetModel.FleetAttention) -> some View {
        let request = item.request
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(request.kind))
                        .foregroundStyle(.tint)
                    Text(request.title).font(.headline)
                    Spacer()
                    Text(request.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !request.body.isEmpty {
                    Text(request.body)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(14)
                }
            }
            .padding(.vertical, 4)

            ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                Button {
                    answer(item, option)
                } label: {
                    HStack {
                        Text(option)
                            .foregroundStyle(Self.isNegative(option) ? .red : .primary)
                        Spacer()
                        if busy == request.id + option { ProgressView() }
                        if request.requiresBiometry { Image(systemName: "faceid").foregroundStyle(.secondary) }
                    }
                }
                .disabled(busy != nil)
                .accessibilityIdentifier("attention-\(request.id)-option-\(index)")
            }

            if request.kind == .question {
                HStack {
                    TextField("Answer in your own words", text: Binding(
                        get: { freeText[request.id] ?? "" },
                        set: { freeText[request.id] = $0 }))
                    Button("Send") {
                        let text = (freeText[request.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { answer(item, text) }
                    }
                    .disabled(busy != nil || (freeText[request.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let cardId = request.cardId {
                Button {
                    dismiss()
                    openCard(cardId)
                } label: {
                    Label("Open card", systemImage: "arrow.up.forward.square")
                }
            }
        } header: {
            Text(item.cardName ?? item.master.machineName)
        }
    }

    private func answer(_ item: FleetModel.FleetAttention, _ resolution: String) {
        busy = item.request.id + resolution
        Task {
            defer { busy = nil }
            if item.request.requiresBiometry {
                guard await Self.authenticate(reason: "\(resolution): \(item.request.title)") else { return }
            }
            do {
                try await item.master.resolveAttention(item.request, resolution: resolution)
                freeText[item.request.id] = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Face ID, or the passcode when Face ID is unavailable.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    static func symbol(_ kind: AttentionRequest.Kind) -> String {
        switch kind {
        case .question: "questionmark.bubble"
        case .planApproval: "list.bullet.clipboard"
        case .permission: "hand.raised"
        case .vaultApproval: "key"
        }
    }

    static func isNegative(_ option: String) -> Bool {
        let lower = option.lowercased()
        return lower.hasPrefix("deny") || lower.hasPrefix("no")
    }
}

/// The "Needs you" row at the top of the board.
struct AttentionBanner: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.orange)
                Text(count == 1 ? "1 decision waiting on you" : "\(count) decisions waiting on you")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier("attentionBanner")
    }
}
