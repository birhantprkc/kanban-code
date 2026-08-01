import Foundation
import KanbanCodeCore

extension ContentView {
    func monitorSubagentCommands() async {
        do {
            let recovered = try await subagentCommandStore.recoverInterruptedRequests()
            if recovered > 0 {
                KanbanCodeLog.warn("subagent", "Recovered \(recovered) interrupted CLI command(s)")
            }
        } catch {
            KanbanCodeLog.error("subagent", "Could not recover interrupted commands: \(error.localizedDescription)")
        }
        while !Task.isCancelled {
            await processPendingSubagentCommands()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

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
            try? await subagentCommandStore.respond(SubagentCommandResponse(
                id: id,
                ok: false,
                error: "Kanban Code could not read this subagent command: \(error.localizedDescription)"
            ))
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
        guard !Self.subagentRequestIsExpired(request.createdAt) else {
            throw SubagentCommandExecutionError.expiredRequest
        }
        guard let parent = await waitForCard(request.parentCardId) else {
            throw SubagentCommandExecutionError.cardNotFound(request.parentCardId)
        }

        switch request.operation {
        case .spawn:
            try await validateSubagentSpawn(parentId: parent.id)
            return try await spawnSubagent(parent: parent, request: request)
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

    private func waitForCard(_ cardId: String) async -> Link? {
        for _ in 0..<100 {
            if let link = store.state.links[cardId] { return link }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return store.state.links[cardId]
    }

    private static func subagentRequestIsExpired(_ createdAt: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
        guard let date else { return true }
        return Date().timeIntervalSince(date) > 120
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

    private func spawnSubagent(parent: Link, request: SubagentCommandRequest) async throws -> String {
        guard let prompt = request.prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubagentCommandExecutionError.missingPrompt
        }
        let assistant = request.assistant ?? parent.effectiveAssistant
        var child = makeSubagentLink(parent: parent, assistant: assistant, model: request.model, prompt: prompt)
        let deliveryPrompt = identifiedSubagentPrompt(prompt, childId: child.id)
        child.promptBody = deliveryPrompt
        store.dispatch(.createManualTask(child))
        let deliveryError = await withCheckedContinuation { continuation in
            executeLaunch(
                cardId: child.id,
                prompt: deliveryPrompt,
                projectPath: effectiveProjectPath(for: parent),
                worktreeName: nil,
                runRemotely: parent.isRemote,
                assistant: assistant,
                serviceIdOverride: child.apiServiceId,
                modelOverride: request.model,
                focusCard: false,
                completion: { continuation.resume(returning: $0) }
            )
        }
        if let deliveryError {
            queueUndeliveredSubagentPrompt(cardId: child.id, prompt: deliveryPrompt)
            throw SubagentCommandExecutionError.promptDelivery(
                cardId: child.id,
                reason: deliveryError
            )
        }
        return child.id
    }

    private func forkSubagent(parent: Link, request: SubagentCommandRequest) async throws -> String {
        guard let prompt = request.prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
            defer {
                try? FileManager.default.removeItem(atPath: forkedPath)
                try? FileManager.default.removeItem(atPath: forkedPath + ".bak")
            }
            let migration = try await SessionMigrator.migrate(
                sourceSessionPath: forkedPath,
                sourceStore: sourceStore,
                targetStore: targetStore,
                projectPath: effectiveProjectPath(for: parent),
                recentTurnLimit: 500,
                recentCharacterLimit: SessionMigrator.defaultCrossAssistantCharacterLimit
            )
            sessionLink = SessionLink(
                sessionId: migration.newSessionId,
                sessionPath: migration.newSessionPath
            )
        }

        var child = makeSubagentLink(
            parent: parent,
            assistant: targetAssistant,
            model: request.model ?? (targetAssistant == sourceAssistant ? parent.modelOverride : nil),
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
            modelOverride: child.modelOverride,
            focusCard: false
        )
        do {
            try await deliverForkGoalWhenReady(
                cardId: child.id,
                assistant: targetAssistant,
                prompt: deliveryPrompt
            )
        } catch {
            queueUndeliveredSubagentPrompt(cardId: child.id, prompt: deliveryPrompt)
            throw error
        }
        return child.id
    }

    private func queueUndeliveredSubagentPrompt(cardId: String, prompt: String) {
        store.dispatch(.addQueuedPrompt(
            cardId: cardId,
            prompt: QueuedPrompt(body: prompt, sendAutomatically: false),
            placement: .front
        ))
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
    ) async throws {
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
                    throw SubagentCommandExecutionError.promptDelivery(
                        cardId: cardId,
                        reason: error.localizedDescription
                    )
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let reason = "timed out waiting for the child tmux session"
        KanbanCodeLog.warn("subagent", "Fork goal \(reason) on \(cardId.prefix(12))")
        throw SubagentCommandExecutionError.promptDelivery(cardId: cardId, reason: reason)
    }
}

private enum SubagentCommandExecutionError: LocalizedError {
    case cardNotFound(String)
    case notOwned(targetId: String, ownerId: String)
    case depthLimit(Int)
    case missingPrompt
    case missingSession(String)
    case assistantUnavailable(CodingAssistant)
    case promptDelivery(cardId: String, reason: String)
    case expiredRequest

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
            "Card \(id) has no session to fork. Use `kanban subagent spawn` to start a new child instead."
        case .assistantUnavailable(let assistant):
            "\(assistant.displayName) is not enabled"
        case .promptDelivery(let cardId, let reason):
            "Subagent \(cardId) was created, but its initial prompt was not delivered: \(reason). Open the child card to recover manually."
        case .expiredRequest:
            "This subagent command expired before Kanban Code could process it. Inspect existing child cards before retrying."
        }
    }
}
