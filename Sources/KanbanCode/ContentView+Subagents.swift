import Foundation
import KanbanCodeCore

extension ContentView {
    func processPendingSubagentCommands() async {
        do {
            for id in try await subagentCommandStore.pendingRequestIds() {
                await processSubagentCommand(id: id)
            }
        } catch {
            KanbanCodeLog.error("subagent", "Could not scan command inbox: \(error.localizedDescription)")
        }
    }

    func processSubagentCommand(id: String) async {
        let request: SubagentCommandRequest
        do {
            guard let claimed = try await subagentCommandStore.claim(id: id) else { return }
            request = claimed
        } catch {
            KanbanCodeLog.error("subagent", "Could not claim command \(id): \(error.localizedDescription)")
            return
        }

        do {
            let cardId = try await executeSubagentCommand(request)
            try await subagentCommandStore.respond(
                SubagentCommandResponse(id: request.id, ok: true, cardId: cardId)
            )
        } catch {
            KanbanCodeLog.error("subagent", "Command \(request.id) failed: \(error.localizedDescription)")
            try? await subagentCommandStore.respond(
                SubagentCommandResponse(id: request.id, ok: false, error: error.localizedDescription)
            )
        }
    }

    private func executeSubagentCommand(_ request: SubagentCommandRequest) async throws -> String? {
        guard let parent = store.state.links[request.parentCardId] else {
            throw SubagentCommandExecutionError.cardNotFound(request.parentCardId)
        }

        switch request.operation {
        case .spawn:
            try await validateSubagentSpawn(parentId: parent.id)
            return try spawnSubagent(parent: parent, request: request)
        case .fork:
            try await validateSubagentSpawn(parentId: parent.id)
            return try await forkSubagent(parent: parent, request: request)
        case .archive:
            let child = try ownedSubagent(from: parent.id, targetId: request.cardId)
            store.dispatch(.archiveCard(cardId: child.id))
            return child.id
        case .resume:
            var child = try ownedSubagent(from: parent.id, targetId: request.cardId)
            child.manuallyArchived = false
            child.column = .inProgress
            child.updatedAt = .now
            store.dispatch(.createManualTask(child))
            executeResume(
                cardId: child.id,
                runRemotely: child.isRemote,
                commandOverride: nil,
                assistant: child.effectiveAssistant,
                serviceIdOverride: child.apiServiceId,
                modelOverride: child.modelOverride,
                focusCard: false
            )
            return child.id
        }
    }

    private func validateSubagentSpawn(parentId: String) async throws {
        let maximumDepth = (try? await settingsStore.read().subagents.maximumDepth) ?? 1
        guard SubagentHierarchy.canSpawn(
            from: parentId,
            in: store.state.links,
            maximumDepth: maximumDepth
        ) else {
            throw SubagentCommandExecutionError.depthLimit(maximumDepth)
        }
    }

    private func ownedSubagent(from ownerId: String, targetId: String?) throws -> Link {
        guard let targetId, let target = store.state.links[targetId] else {
            throw SubagentCommandExecutionError.cardNotFound(targetId ?? "missing")
        }
        guard SubagentHierarchy.descendantIds(of: ownerId, in: store.state.links).contains(targetId) else {
            throw SubagentCommandExecutionError.notOwned(targetId: targetId, ownerId: ownerId)
        }
        return target
    }

    private func spawnSubagent(parent: Link, request: SubagentCommandRequest) throws -> String {
        guard let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw SubagentCommandExecutionError.missingPrompt
        }
        let assistant = request.assistant ?? parent.effectiveAssistant
        var child = makeSubagentLink(parent: parent, assistant: assistant, model: request.model, prompt: prompt)
        let deliveryPrompt = identifiedSubagentPrompt(prompt, childId: child.id)
        child.promptBody = deliveryPrompt
        store.dispatch(.createManualTask(child))
        executeLaunch(
            cardId: child.id,
            prompt: deliveryPrompt,
            projectPath: effectiveProjectPath(for: parent),
            worktreeName: nil,
            runRemotely: parent.isRemote,
            assistant: assistant,
            serviceIdOverride: child.apiServiceId,
            modelOverride: request.model,
            focusCard: false
        )
        return child.id
    }

    private func forkSubagent(parent: Link, request: SubagentCommandRequest) async throws -> String {
        guard let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw SubagentCommandExecutionError.missingPrompt
        }
        guard let sourcePath = parent.sessionLink?.sessionPath else {
            throw SubagentCommandExecutionError.missingSession(parent.id)
        }
        let sourceAssistant = parent.effectiveAssistant
        let targetAssistant = request.assistant ?? sourceAssistant
        guard let sourceStore = assistantRegistry.store(for: sourceAssistant),
              let targetStore = assistantRegistry.store(for: targetAssistant) else {
            throw SubagentCommandExecutionError.assistantUnavailable(targetAssistant)
        }

        let forkedId = try await sourceStore.forkSession(sessionPath: sourcePath, targetDirectory: nil)
        let forkedPath = Self.forkedSessionPath(
            assistant: sourceAssistant,
            sessionId: forkedId,
            directory: (sourcePath as NSString).deletingLastPathComponent
        )

        let sessionLink: SessionLink
        if targetAssistant == sourceAssistant {
            sessionLink = SessionLink(sessionId: forkedId, sessionPath: forkedPath)
        } else {
            let migration = try await SessionMigrator.migrate(
                sourceSessionPath: forkedPath,
                sourceStore: sourceStore,
                targetStore: targetStore,
                projectPath: effectiveProjectPath(for: parent),
                recentTurnLimit: 500
            )
            sessionLink = SessionLink(
                sessionId: migration.newSessionId,
                sessionPath: migration.newSessionPath
            )
        }

        var child = makeSubagentLink(
            parent: parent,
            assistant: targetAssistant,
            model: request.model,
            prompt: prompt
        )
        let deliveryPrompt = identifiedSubagentPrompt(prompt, childId: child.id)
        child.promptBody = deliveryPrompt
        child.sessionLink = sessionLink
        store.dispatch(.createManualTask(child))
        executeResume(
            cardId: child.id,
            runRemotely: parent.isRemote,
            commandOverride: nil,
            assistant: targetAssistant,
            serviceIdOverride: child.apiServiceId,
            modelOverride: request.model,
            focusCard: false
        )
        deliverForkGoalWhenReady(cardId: child.id, assistant: targetAssistant, prompt: deliveryPrompt)
        return child.id
    }

    private func makeSubagentLink(
        parent: Link,
        assistant: CodingAssistant,
        model: String?,
        prompt: String
    ) -> Link {
        var child = Link(
            name: subagentTitle(from: prompt),
            projectPath: parent.projectPath,
            column: .inProgress,
            source: .manual,
            promptBody: prompt,
            parentCardId: parent.id,
            modelOverride: model,
            worktreeLink: parent.worktreeLink,
            assistant: assistant,
            isRemote: parent.isRemote
        )
        child.apiServiceId = assistant == parent.effectiveAssistant ? parent.apiServiceId : nil
        return child
    }

    private func subagentTitle(from prompt: String) -> String {
        let goal = prompt.components(separatedBy: "\nGoal:\n").last ?? prompt
        let firstLine = goal.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Subagent"
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Subagent" : trimmed).prefix(80))
    }

    private func identifiedSubagentPrompt(_ prompt: String, childId: String) -> String {
        "You are running as subagent card \(childId).\n\(prompt)"
    }

    private func effectiveProjectPath(for link: Link) -> String {
        if let worktree = link.worktreeLink?.path, !worktree.isEmpty { return worktree }
        return link.projectPath ?? NSHomeDirectory()
    }

    private func deliverForkGoalWhenReady(
        cardId: String,
        assistant: CodingAssistant,
        prompt: String
    ) {
        Task {
            for _ in 0..<120 {
                if let sessionName = store.state.links[cardId]?.tmuxLink?.sessionName,
                   let liveSessions = try? await tmuxAdapter.listSessions(),
                   liveSessions.contains(where: { $0.name == sessionName }) {
                    do {
                        let sender = ImageSender(tmux: tmuxAdapter)
                        try await sender.waitForReady(sessionName: sessionName, assistant: assistant)
                        if assistant.submitsPromptWithPaste {
                            try await tmuxAdapter.pastePrompt(to: sessionName, text: prompt)
                        } else {
                            try await tmuxAdapter.sendPrompt(to: sessionName, text: prompt)
                        }
                        return
                    } catch {
                        KanbanCodeLog.warn(
                            "subagent",
                            "Could not deliver fork goal to \(cardId.prefix(12)): \(error.localizedDescription)"
                        )
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            KanbanCodeLog.warn("subagent", "Fork goal timed out waiting for tmux on \(cardId.prefix(12))")
        }
    }
}

private enum SubagentCommandExecutionError: LocalizedError {
    case cardNotFound(String)
    case notOwned(targetId: String, ownerId: String)
    case depthLimit(Int)
    case missingPrompt
    case missingSession(String)
    case assistantUnavailable(CodingAssistant)

    var errorDescription: String? {
        switch self {
        case .cardNotFound(let id):
            "Card \(id) was not found"
        case .notOwned(let targetId, let ownerId):
            "Card \(targetId) is not a subagent owned by \(ownerId)"
        case .depthLimit(let maximumDepth):
            "You already reached the user-defined maximum subagent depth of \(maximumDepth). You cannot spawn another subagent. Do the work yourself."
        case .missingPrompt:
            "A subagent goal is required"
        case .missingSession(let id):
            "Card \(id) has no session to fork"
        case .assistantUnavailable(let assistant):
            "\(assistant.displayName) is not enabled"
        }
    }
}
