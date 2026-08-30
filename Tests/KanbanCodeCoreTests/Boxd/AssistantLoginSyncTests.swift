import Foundation
import Testing
@testable import KanbanCodeCore

private func withLock<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

/// A login store held in memory.
final class FakeLoginStore: LocalLoginStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _logins: [AssistantLoginKind: Data] = [:]
    private var _account: [String: Any]?
    private var _writes: [AssistantLoginKind] = []

    init(logins: [AssistantLoginKind: Data] = [:], account: [String: Any]? = nil) {
        _logins = logins
        _account = account
    }

    var writes: [AssistantLoginKind] { withLock(lock) { _writes } }
    func data(_ kind: AssistantLoginKind) -> Data? { withLock(lock) { _logins[kind] } }

    func read(_ kind: AssistantLoginKind) async -> Data? { withLock(lock) { _logins[kind] } }
    func write(_ kind: AssistantLoginKind, data: Data) async throws {
        withLock(lock) {
            _logins[kind] = data
            _writes.append(kind)
        }
    }
    func claudeAccount() async -> [String: Any]? { withLock(lock) { _account } }
}

private func claudeLogin(access: String, expiresAt: Int) -> Data {
    let json = """
    {"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"sk-ant-ort01-r","expiresAt":\(expiresAt),"scopes":["user:inference"],"subscriptionType":"max"}}
    """
    return json.data(using: .utf8)!
}

private func codexLogin(refreshed: String?, token: String = "id") -> Data {
    let refresh = refreshed.map { ",\"last_refresh\":\"\($0)\"" } ?? ""
    return "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"id_token\":\"\(token)\"}\(refresh)}".data(using: .utf8)!
}

@Suite("Assistant logins")
struct AssistantLoginTests {
    @Test("A Claude login is as fresh as its expiry")
    func claudeFreshness() throws {
        let login = try #require(AssistantLogin(kind: .claude, data: claudeLogin(access: "a", expiresAt: 1_788_125_398_307)))
        #expect(login.freshness == 1_788_125_398.307)
    }

    @Test("A Codex login is as fresh as its last refresh")
    func codexFreshness() throws {
        let login = try #require(AssistantLogin(kind: .codex, data: codexLogin(refreshed: "2026-08-21T12:59:57.237947Z")))
        #expect(abs(login.freshness - 1_787_317_197.238) < 0.01)
        let noDate = try #require(AssistantLogin(kind: .codex, data: codexLogin(refreshed: nil)))
        #expect(noDate.freshness == 0)
    }

    @Test("Bytes that hold no token are not a login")
    func rejectsNonLogins() {
        #expect(AssistantLogin(kind: .claude, data: Data("not json".utf8)) == nil)
        #expect(AssistantLogin(kind: .claude, data: Data("{\"claudeAiOauth\":{\"accessToken\":\"\"}}".utf8)) == nil)
        #expect(AssistantLogin(kind: .claude, data: Data("{\"mcpOAuth\":{}}".utf8)) == nil)
        #expect(AssistantLogin(kind: .codex, data: Data("{\"tokens\":{}}".utf8)) == nil)
    }

    @Test("The newest copy wins, the Mac on a tie")
    func decision() {
        let older = AssistantLogin(kind: .claude, data: claudeLogin(access: "old", expiresAt: 1_000))
        let newer = AssistantLogin(kind: .claude, data: claudeLogin(access: "new", expiresAt: 2_000))
        let sameAge = AssistantLogin(kind: .claude, data: claudeLogin(access: "other", expiresAt: 2_000))
        #expect(AssistantLogin.decide(local: nil, remote: nil) == .none)
        #expect(AssistantLogin.decide(local: newer, remote: nil) == .push)
        #expect(AssistantLogin.decide(local: nil, remote: newer) == .pull)
        #expect(AssistantLogin.decide(local: newer, remote: newer) == .none)
        #expect(AssistantLogin.decide(local: newer, remote: older) == .push)
        #expect(AssistantLogin.decide(local: older, remote: newer) == .pull)
        #expect(AssistantLogin.decide(local: newer, remote: sameAge) == .push)
    }

    @Test("Paths of the login files on a machine")
    func remotePaths() {
        #expect(AssistantLoginKind.claude.remoteRelativePath == ".claude/.credentials.json")
        #expect(AssistantLoginKind.codex.remoteRelativePath == ".codex/auth.json")
        let script = AssistantLoginSync.readScript(remoteHome: "/home/boxd")
        #expect(script.contains("'/home/boxd/.claude/.credentials.json' '/home/boxd/.codex/auth.json'"))
        #expect(script.contains("base64 -w0"))
    }
}

@Suite("Assistant login sync")
struct AssistantLoginSyncTests {
    private let home = "/home/boxd"

    private func remoteAnswer(claude: Data?, codex: Data?) -> ShellCommand.Result {
        let lines = [claude, codex].map { $0?.base64EncodedString() ?? "" }
        return ShellCommand.Result(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }

    private func readCall() -> [String] {
        ["bash", "-c", AssistantLoginSync.readScript(remoteHome: home)]
    }

    @Test("A newer login on the Mac goes to the machine with the account")
    func pushesNewerLocal() async {
        let local = claudeLogin(access: "new", expiresAt: 2_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: claudeLogin(access: "old", expiresAt: 1_000), codex: nil))
        let store = FakeLoginStore(logins: [.claude: local], account: ["accountUuid": "u1", "emailAddress": "a@b.c"])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .claude, decision: .push)])
        #expect(runner.files["/home/boxd/.claude/.credentials.json"] == local)
        #expect(runner.mode(of: "/home/boxd/.claude/.credentials.json") == 0o600)
        let node = runner.execCalls.first { $0.first == "/usr/local/bin/node" }
        #expect(node?[2].contains("config.oauthAccount = {") == true)
        #expect(node?[2].contains("\"accountUuid\":\"u1\"") == true)
        #expect(node?[2].contains("/home/boxd/.claude.json") == true)
        #expect(store.writes.isEmpty)
    }

    @Test("A newer login on the machine comes back to the Mac")
    func pullsNewerRemote() async {
        let remote = claudeLogin(access: "refreshed", expiresAt: 3_000)
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: remote, codex: nil))
        let store = FakeLoginStore(logins: [.claude: claudeLogin(access: "old", expiresAt: 2_000)])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .claude, decision: .pull)])
        #expect(store.data(.claude) == remote)
        #expect(runner.files.isEmpty)
    }

    @Test("Equal copies move nothing, each assistant on its own")
    func equalCopiesAndCodex() async {
        let claude = claudeLogin(access: "same", expiresAt: 2_000)
        let codexLocal = codexLogin(refreshed: "2026-08-21T12:59:57Z", token: "new")
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), remoteAnswer(claude: claude, codex: codexLogin(refreshed: "2026-08-01T00:00:00Z", token: "old")))
        let store = FakeLoginStore(logins: [.claude: claude, .codex: codexLocal])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .codex, decision: .push)])
        #expect(runner.files["/home/boxd/.codex/auth.json"] == codexLocal)
        #expect(runner.files["/home/boxd/.claude/.credentials.json"] == nil)
    }

    @Test("A machine without login files gets the Mac's")
    func seedsEmptyMachine() async {
        let runner = FakeRemoteCommandRunner()
        runner.script(readCall(), ShellCommand.Result(exitCode: 0, stdout: "\n\n", stderr: ""))
        let local = claudeLogin(access: "mine", expiresAt: 2_000)
        let store = FakeLoginStore(logins: [.claude: local])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes == [AssistantLoginSync.Change(kind: .claude, decision: .push)])
        #expect(runner.files["/home/boxd/.claude/.credentials.json"] == local)
    }

    @Test("A failed read moves nothing")
    func failedReadMovesNothing() async {
        let runner = FakeRemoteCommandRunner()
        runner.setFallback(ShellCommand.Result(exitCode: 1, stdout: "", stderr: "boom"))
        let store = FakeLoginStore(logins: [.claude: claudeLogin(access: "mine", expiresAt: 2_000)])

        let changes = await AssistantLoginSync(runner: runner, store: store, remoteHome: home).run()

        #expect(changes.isEmpty)
        #expect(runner.files.isEmpty)
    }
}
