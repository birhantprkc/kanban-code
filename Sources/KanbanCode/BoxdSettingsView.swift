import SwiftUI
import KanbanCodeCore

// MARK: - Remote mode copy

extension RemoteMode {
    /// Title of the mode in the Remote settings tab.
    var settingsTitle: String {
        switch self {
        case .boxd: "Boxd integration"
        case .mutagen: "Mutagen + Claude Remote Exec"
        }
    }

    /// One paragraph that tells the user what the mode does.
    var settingsDescription: String {
        switch self {
        case .boxd:
            "Create cloud sandboxes for each coding assistant and run tmux and coding sessions fully remotely, but sync back jsonl to keep all conversations. Requires a boxd account."
        case .mutagen:
            "Sync files with a remote machine, run the tmux and coding assistant locally but executing commands remotely. Best for delegating cpu and ram resources locally but resilient to network latency disconnects. Works with any linux remote machine."
        }
    }
}

// MARK: - Boxd form

/// Form sections of the boxd remote mode. Used inside the `Form` of the
/// Remote settings tab, so the body is a set of `Section`s.
struct BoxdSettingsView: View {
    @State private var snapshotName = BoxdSettings.defaultSnapshotName
    @State private var sourceMachine = BoxdSettings.defaultSourceMachine
    @State private var folderTemplate = BoxdSettings.defaultFolderTemplate
    @State private var initCommand = BoxdSettings.defaultInitCommand
    @State private var copyGlobsText = BoxdSettings.defaultCopyGlobs.joined(separator: "\n")
    @State private var inactivityMinutes = BoxdSettings.defaultInactivityTimeoutSeconds / 60
    @State private var claudeOAuthToken = ""

    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    @State private var boxdAvailable = true
    @State private var machines: [String] = []
    @State private var isSavingSnapshot = false
    @State private var snapshotMessage: String?
    @State private var snapshotFailed = false

    private let settingsStore = SettingsStore()

    /// Shortest timeout the settings accept, in minutes.
    private static let minimumMinutes = max(1, BoxdSettings.minimumInactivityTimeoutSeconds / 60)

    var body: some View {
        if !boxdAvailable {
            Section("Dependency") {
                HStack {
                    Label("boxd", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("https://boxd.sh")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Text("Install the boxd CLI and log in: https://boxd.sh")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }

        Section("Machine") {
            HStack {
                TextField("Snapshot", text: $snapshotName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: snapshotName) { scheduleSave() }
                if isSavingSnapshot {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Create snapshot now") { createSnapshot() }
                    .controlSize(.small)
                    .disabled(isSavingSnapshot || trimmedSnapshotName.isEmpty || trimmedSourceMachine.isEmpty)
            }

            if let snapshotMessage {
                Text(snapshotMessage)
                    .font(.caption)
                    .foregroundStyle(snapshotFailed ? Color.red : Color.green)
                    .textSelection(.enabled)
            }

            Text("Every machine is created from this snapshot.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if machines.isEmpty {
                TextField("Source machine", text: $sourceMachine)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: sourceMachine) { scheduleSave() }
            } else {
                Picker("Source machine", selection: $sourceMachine) {
                    ForEach(machineOptions, id: \.self) { machine in
                        Text(machine).tag(machine)
                    }
                }
                .onChange(of: sourceMachine) { scheduleSave() }
            }

            Text("The snapshot is saved from this machine.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }

        Section("Project") {
            TextField("Project folder", text: $folderTemplate)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onChange(of: folderTemplate) { scheduleSave() }
            Text("`${repo_name}` is the GitHub repository name of the project.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Initialization command")
                TextEditor(text: $initCommand)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 110)
                    .onChange(of: initCommand) { scheduleSave() }
                Text("Runs on the machine before each session. Variables: `${repo_dir}`, `${repo_url}`, `${repo_name}`, `${branch}`.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Files to copy")
                TextEditor(text: $copyGlobsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 60)
                    .onChange(of: copyGlobsText) { scheduleSave() }
                Text("Copied from the local project into the machine after the initialization command. One glob per line.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }

        Section("Claude login") {
            SecureField("Claude token", text: $claudeOAuthToken)
                .textFieldStyle(.roundedBorder)
                .onChange(of: claudeOAuthToken) { scheduleSave() }
            Text("Machines made from the snapshot share the Claude login of the source machine, and a token refresh on one machine logs the others out. Run `claude setup-token` on this Mac and paste the token here. Every session on a machine then uses it as CLAUDE_CODE_OAUTH_TOKEN.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }

        Section("Lifecycle") {
            HStack {
                Text("Pause after inactivity")
                Spacer()
                TextField("", value: $inactivityMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Text("minutes")
                    .foregroundStyle(.secondary)
                Stepper("", value: $inactivityMinutes, in: Self.minimumMinutes...1440)
                    .labelsHidden()
            }
            .onChange(of: inactivityMinutes) { scheduleSave() }

            Text("The machine is paused when the session shows no activity for this long.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .task { await load() }
    }

    // MARK: - Derived values

    private var trimmedSnapshotName: String {
        snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSourceMachine: String {
        sourceMachine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Machine names of the picker. The saved machine stays in the list even
    /// when the CLI does not report it any more.
    private var machineOptions: [String] {
        var options = machines
        let current = trimmedSourceMachine
        if !current.isEmpty && !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options
    }

    // MARK: - Loading and saving

    private func load() async {
        let settings = try? await settingsStore.read()
        let boxd = settings?.boxd ?? BoxdSettings()
        snapshotName = boxd.snapshotName
        sourceMachine = boxd.sourceMachine
        folderTemplate = boxd.folderTemplate
        initCommand = boxd.initCommand
        copyGlobsText = boxd.copyGlobs.joined(separator: "\n")
        inactivityMinutes = max(Self.minimumMinutes, boxd.inactivityTimeoutSeconds / 60)
        claudeOAuthToken = boxd.claudeOAuthToken
        loaded = true

        let adapter = BoxdCliAdapter()
        boxdAvailable = await adapter.isAvailable()
        if boxdAvailable {
            machines = ((try? await adapter.listMachines()) ?? [])
                .map(\.name)
                .filter { !$0.isEmpty }
                .sorted()
        }
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        let boxd = currentSettings()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard var settings = try? await settingsStore.read() else { return }
            settings.boxd = boxd
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func currentSettings() -> BoxdSettings {
        BoxdSettings(
            snapshotName: trimmedSnapshotName,
            sourceMachine: trimmedSourceMachine,
            folderTemplate: folderTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
            initCommand: initCommand,
            copyGlobs: copyGlobsText
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            inactivityTimeoutSeconds: max(Self.minimumMinutes, inactivityMinutes) * 60,
            claudeOAuthToken: claudeOAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Snapshot

    private func createSnapshot() {
        let machine = trimmedSourceMachine
        let name = trimmedSnapshotName
        isSavingSnapshot = true
        snapshotMessage = nil
        snapshotFailed = false
        Task {
            do {
                try await BoxdCliAdapter().saveSnapshot(machine: machine, name: name)
                snapshotMessage = "Snapshot \(name) saved"
                snapshotFailed = false
            } catch {
                snapshotMessage = error.localizedDescription
                snapshotFailed = true
            }
            isSavingSnapshot = false
        }
    }
}
