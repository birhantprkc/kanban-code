import Foundation
import KanbanCodeCore

extension ContentView {
    /// Where a card's Claude session runs, from the settings and the launch.
    func agtopChoice(
        settings: Settings?,
        assistant: CodingAssistant,
        remote: Bool,
        commandOverride: String?
    ) -> AgtopLaunchPlanner.Choice {
        let choice = AgtopLaunchPlanner.choose(
            assistant: assistant,
            runtime: settings?.runtime(for: assistant) ?? .tmux,
            remote: remote,
            commandOverride: commandOverride,
            agtopInstalled: tmuxAdapter.agtop.isAvailable
        )
        if case .fallback(let fallback) = choice {
            KanbanCodeLog.info("agtop", "Running on tmux: \(fallback.reason)")
            if fallback == .notInstalled {
                store.dispatch(.setError("agtop is not installed, the session runs on tmux"))
            }
        }
        return choice
    }

    /// Starts, or resumes, a card's Claude session on an agtop host and
    /// returns its session name (`agtop-<id>`).
    func startOnAgtop(
        cardId: String,
        cwd: String,
        sessionId: String,
        resume: Bool,
        prompt: String?,
        images: [ImageAttachment],
        extraEnv: [String: String],
        skipPermissions: Bool,
        model: String?,
        commandTemplate: String?,
        service: APIService?
    ) async throws -> String {
        let imagePaths = images.compactMap { image -> String? in
            if let tempPath = image.tempPath { return tempPath }
            var copy = image
            return try? copy.saveToTemp()
        }
        let text = prompt.map { PromptImageLayout.replacingMarkersWithMarkdown(in: $0, imagePaths: imagePaths) }
        let binary = try AgtopLaunchPlanner.wrapperCommand(template: commandTemplate, service: service)
            .map { try Self.writeAgtopWrapper(cardId: cardId, command: $0) }
        let request = AgtopLaunchPlanner.request(
            cardId: cardId,
            cwd: cwd,
            sessionId: sessionId,
            resume: resume,
            name: store.state.links[cardId]?.name,
            prompt: text,
            imagePaths: imagePaths,
            extraEnv: extraEnv,
            skipPermissions: skipPermissions,
            model: model ?? service?.modelFlag,
            binary: binary
        )
        let info = try await tmuxAdapter.agtop.start(request)
        let name = AgtopSessionName.name(agtopId: info.id)
        KanbanCodeLog.info("agtop", "Started \(name) for card=\(cardId.prefix(12)) session=\(sessionId.prefix(8)) resume=\(resume)")
        return name
    }

    /// Stops the tmux sessions of `sessionId` so its agtop host is the only
    /// process writing the transcript.
    func killTmuxSessions(of sessionId: String) async {
        let sid8 = String(sessionId.prefix(8))
        guard let sessions = try? await tmuxAdapter.listSessions() else { return }
        for session in sessions where session.name.contains(sid8) && !AgtopSessionName.isAgtop(session.name) {
            try? await tmuxAdapter.killSession(name: session.name)
        }
    }

    /// The transcript Claude writes for a session started in `cwd`.
    static func claudeTranscriptPath(cwd: String, sessionId: String) -> String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        return "\(dir)/\(SessionFileMover.encodeProjectPath(cwd))/\(sessionId).jsonl"
    }

    private static func writeAgtopWrapper(cardId: String, command: String) throws -> String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/agtop")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(cardId)-claude.sh"
        try AgtopLaunchPlanner.wrapperScript(command: command).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}
