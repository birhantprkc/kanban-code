import KanbanCodeCore
import SwiftUI

/// Settings > Vault, the scrubber: the daily run that replaces secrets in
/// this machine's transcripts with `{{vault:NAME}}` references, its
/// schedule, a manual run and the last result of every master.
struct ScrubSettingsSection: View {
    @State private var status: ScrubStatus?
    @State private var peers: [String: ScrubStatus] = [:]
    @State private var enabled = true
    @State private var time = Date()

    private var scrubber: SecretScrubber { AppComposition.shared.scrubber }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("Replace secrets in transcripts every day at", isOn: $enabled)
                        .onChange(of: enabled) { _, _ in save() }
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 90)
                        .disabled(!enabled)
                        .onChange(of: time) { _, _ in save() }
                    Spacer()
                    if status?.running == true {
                        ProgressView().controlSize(.small)
                        Text(status?.progress ?? "running").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Dry Run") { run(dryRun: true) }
                        .disabled(status?.running == true)
                        .help("Count what a run would replace, on every master. Nothing changes.")
                    Button("Run Now") { run(dryRun: false) }
                        .disabled(status?.running == true)
                }
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Claude Code and Codex transcripts, rush drafts, Kanban's own stores and the OptMem log, on this Mac and on each paired master. A value the vault holds, or a key in a vendor's format, becomes {{vault:NAME}}; one the vault did not hold is saved first under scrubbed/found, tier ask. Files written in the last 10 minutes wait for the next run. This cleans local files only: what already reached a model provider, a remote log or a backup elsewhere stays there, so rotate a key that leaked.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
        .task {
            await load(first: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(status?.running == true ? 2 : 15))
                await load(first: false)
            }
        }
    }

    private var lines: [String] {
        var all: [(String, ScrubStatus)] = []
        if let status { all.append(("This Mac", status)) }
        all += peers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return all.flatMap { name, status in
            [status.lastRun, status.lastDryRun].compactMap { $0 }
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(1)
                .map { Self.summary(name, $0) }
                + (status.lastRun == nil && status.lastDryRun == nil ? ["\(name): no run yet"] : [])
        }
    }

    static func summary(_ name: String, _ report: ScrubReport) -> String {
        let when = report.finishedAt.formatted(date: .abbreviated, time: .shortened)
        if let note = report.note { return "\(name), \(when): \(note)" }
        let kind = report.dryRun ? "dry run, would replace" : "replaced"
        var text = "\(name), \(when): \(kind) \(report.replacements) values in \(report.filesWithSecrets) files"
        if report.newSecrets > 0 { text += ", \(report.newSecrets) not in the vault before" }
        if report.filesLive > 0 { text += ", \(report.filesLive) live files left for the next run" }
        if !report.errors.isEmpty { text += ", \(report.errors.count) errors (kv scrub --status)" }
        return text
    }

    private func load(first: Bool) async {
        let current = await scrubber.status()
        status = current
        if first {
            enabled = current.schedule.enabled
            time = Calendar.current.date(bySettingHour: current.schedule.hour, minute: current.schedule.minute, second: 0, of: Date()) ?? Date()
        }
        peers = await scrubber.peerStatuses()
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let schedule = ScrubSchedule(enabled: enabled, hour: parts.hour ?? 4, minute: parts.minute ?? 30)
        guard schedule != status?.schedule else { return }
        status?.schedule = schedule
        Task { await scrubber.setSchedule(schedule, share: true) }
    }

    private func run(dryRun: Bool) {
        Task {
            await scrubber.start(dryRun: dryRun)
            await scrubber.runOnPeers(dryRun: dryRun)
            await load(first: false)
        }
    }
}
