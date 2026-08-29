import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Assistant command template")
struct AssistantCommandTemplateTests {

    final class RecordingTmux: TmuxManagerPort, @unchecked Sendable {
        var lastCommand: String?

        func createSession(name: String, path: String, command: String?) async throws {
            lastCommand = command
        }
        func killSession(name: String) async throws {}
        func listSessions() async throws -> [TmuxSession] { [] }
        func sendPrompt(to sessionName: String, text: String) async throws {}
        func pastePrompt(to sessionName: String, text: String) async throws {}
        func pasteText(to sessionName: String, text: String) async throws {}
        func submitPrompt(to sessionName: String) async throws {}
        func capturePane(sessionName: String) async throws -> String { "" }
        func sendBracketedPaste(to sessionName: String) async throws {}
        func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
        func isAvailable() async -> Bool { true }
    }

    // MARK: - applyCommandTemplate

    @Test("No template leaves the command as it is")
    func noTemplate() {
        #expect(CodingAssistant.applyCommandTemplate("claude --resume abc", template: nil) == "claude --resume abc")
        #expect(CodingAssistant.applyCommandTemplate("claude", template: "") == "claude")
        #expect(CodingAssistant.applyCommandTemplate("claude", template: "   \n ") == "claude")
        #expect(CodingAssistant.applyCommandTemplate("claude", template: "${cli_command}") == "claude")
    }

    @Test("The placeholder is replaced wherever it stands")
    func placeholderReplaced() {
        #expect(CodingAssistant.applyCommandTemplate("claude -x", template: "langwatch ${cli_command}") == "langwatch claude -x")
        #expect(CodingAssistant.applyCommandTemplate("claude -x", template: "${cli_command} --rc") == "claude -x --rc")
        #expect(
            CodingAssistant.applyCommandTemplate("claude", template: "echo ${cli_command} && ${cli_command}")
                == "echo claude && claude"
        )
    }

    @Test("A template without the placeholder becomes a prefix")
    func templateWithoutPlaceholder() {
        #expect(CodingAssistant.applyCommandTemplate("claude -x", template: "langwatch") == "langwatch claude -x")
    }

    // MARK: - LaunchSession

    @Test("The template wraps the command and the env prefix stays in front")
    func launchOrdering() async throws {
        let tmux = RecordingTmux()
        let launcher = LaunchSession(tmux: tmux)

        _ = try await launcher.launch(
            sessionName: "card",
            projectPath: "/tmp/project",
            prompt: "fix it",
            worktreeName: nil,
            shellOverride: "/bin/bash",
            commandTemplate: "langwatch ${cli_command}",
            skipPermissions: true,
            assistant: .claude
        )

        let command = try #require(tmux.lastCommand)
        #expect(command.contains("SHELL=/bin/bash langwatch claude --dangerously-skip-permissions"))
        #expect(command.hasPrefix("cd '/tmp/project' && SHELL="))
    }

    @Test("A trailing-flag template is applied on resume too")
    func resumeTrailingFlags() async throws {
        let tmux = RecordingTmux()
        let launcher = LaunchSession(tmux: tmux)

        _ = try await launcher.resume(
            sessionId: "abcdef12-3456",
            projectPath: "/tmp/project",
            shellOverride: nil,
            commandTemplate: "${cli_command} --rc",
            skipPermissions: false,
            assistant: .claude
        )

        let command = try #require(tmux.lastCommand)
        #expect(command.hasSuffix("claude --resume abcdef12-3456 --rc"))
    }

    @Test("A template without a placeholder still prefixes the resume command")
    func resumePrefixOnly() async throws {
        let tmux = RecordingTmux()
        let launcher = LaunchSession(tmux: tmux)

        _ = try await launcher.resume(
            sessionId: "abcdef12",
            projectPath: "/tmp/project",
            shellOverride: nil,
            commandTemplate: "langwatch",
            assistant: .codex
        )

        let command = try #require(tmux.lastCommand)
        #expect(command.contains("langwatch codex resume"))
    }

    @Test("An explicit command override ignores the template")
    func overrideWins() async throws {
        let tmux = RecordingTmux()
        let launcher = LaunchSession(tmux: tmux)

        _ = try await launcher.launch(
            sessionName: "card",
            projectPath: "/tmp/project",
            prompt: "fix it",
            worktreeName: nil,
            shellOverride: "/bin/bash",
            commandOverride: "echo hello",
            commandTemplate: "langwatch ${cli_command}",
            assistant: .claude
        )

        let command = try #require(tmux.lastCommand)
        #expect(command == "cd '/tmp/project' && echo hello")
    }

    @Test("No template keeps the command Kanban Code builds")
    func noTemplateOnLaunch() async throws {
        let tmux = RecordingTmux()
        let launcher = LaunchSession(tmux: tmux)

        _ = try await launcher.launch(
            sessionName: "card",
            projectPath: "/tmp/project",
            prompt: "fix it",
            worktreeName: nil,
            shellOverride: nil,
            skipPermissions: true,
            assistant: .claude
        )

        let command = try #require(tmux.lastCommand)
        #expect(command == "cd '/tmp/project' && claude --dangerously-skip-permissions")
    }
}
