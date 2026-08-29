import SwiftUI
import KanbanCodeCore

// MARK: - Boxd machines (toolbar pill)

extension ContentView {
    /// One pill for every boxd machine the app knows: how many run, how
    /// many are paused, with a popover to pause or destroy each one.
    @ViewBuilder
    var boxdStatusView: some View {
        let states = store.state.remoteMachineStates
        let connected = states.values.filter(\.isConnected).count
        let paused = states.values.filter(\.isPaused).count
        Button { showBoxdPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: connected > 0 ? "cloud.fill" : "cloud")
                    .foregroundStyle(connected > 0 ? Color.teal : Color.secondary)
                if !isExpandedDetail {
                    Text(boxdPillLabel(connected: connected, paused: paused, total: states.count))
                        .font(.app(.headline))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, isExpandedDetail ? 12 : 8)
        }
        .buttonStyle(.plain)
        .help(boxdPillLabel(connected: connected, paused: paused, total: states.count))
        .popover(isPresented: $showBoxdPopover) {
            boxdStatusPopover
        }
    }

    private func boxdPillLabel(connected: Int, paused: Int, total: Int) -> String {
        if connected > 0 { return connected == 1 ? "1 machine running" : "\(connected) machines running" }
        if paused > 0 { return paused == 1 ? "1 machine paused" : "\(paused) machines paused" }
        return total == 1 ? "1 machine" : "\(total) machines"
    }

    @ViewBuilder
    var boxdStatusPopover: some View {
        let states = store.state.remoteMachineStates.sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 10) {
            Text("Boxd machines of the cards on this board. Machines bill while they run and are paused when a session stops, after inactivity, and when the app quits.")
                .font(.app(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(states, id: \.key) { name, state in
                let cardIds = store.state.cardIds(onMachine: name)
                HStack(spacing: 8) {
                    Image(systemName: state.isConnected ? "cloud.fill" : state.isPaused ? "pause.circle" : "exclamationmark.icloud")
                        .foregroundStyle(state.isConnected ? Color.teal : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.app(.callout))
                        Text("\(state.label) · \(cardIds.count) card\(cardIds.count == 1 ? "" : "s")")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.isConnected, let cardId = cardIds.first {
                        Button("Pause") {
                            store.dispatch(.pauseRemoteMachine(cardId: cardId, reason: .manual))
                        }
                        .controlSize(.small)
                    }
                    if !state.isConnected, let cardId = cardIds.first {
                        Button("Destroy", role: .destructive) {
                            showBoxdPopover = false
                            presentDialog(.confirmDestroyMachine(cardId: cardId))
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
