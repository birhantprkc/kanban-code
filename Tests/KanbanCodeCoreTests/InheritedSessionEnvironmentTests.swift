import Testing
@testable import KanbanCodeCore

@Suite("Environment inherited from an agent session")
struct InheritedSessionEnvironmentTests {
    @Test("An app launched from a rush session's shell drops what that session set")
    func dropsSessionMarkers() {
        let env = [
            "RUSH_SESSION": "8c76706f",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_SESSION_ID": "8c76706f-1c00",
            "CLAUDE_PID": "2024",
            "KANBAN_CARD_ID": "card_x",
            "TMPDIR": "/Users/me/.config/agtop/sessions/8c76706f/tmp",
            "HOME": "/Users/me",
            "PATH": "/usr/bin",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
        ]
        #expect(InheritedSessionEnvironment.inherited(in: env) == [
            "CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "KANBAN_CARD_ID", "RUSH_SESSION", "TMPDIR",
        ])
    }

    @Test("A TMPDIR of the user's own stays")
    func keepsOwnTmpdir() {
        #expect(InheritedSessionEnvironment.inherited(in: ["TMPDIR": "/var/folders/ab/T/", "HOME": "/Users/me"]).isEmpty)
    }
}
