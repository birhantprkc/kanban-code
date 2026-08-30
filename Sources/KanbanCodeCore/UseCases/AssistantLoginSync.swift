import Foundation

/// The login file of a coding assistant.
///
/// Claude Code keeps its OAuth tokens in the Keychain on macOS and in
/// `~/.claude/.credentials.json` on Linux, with the same JSON inside. Codex
/// keeps `~/.codex/auth.json` on both. Both rotate the refresh token on
/// every refresh, so a copy on a machine drifts from the copy on the Mac
/// within hours and one of them shows "Login expired". Kanban Code keeps the
/// copies equal: the newest one wins, in both directions.
public enum AssistantLoginKind: String, CaseIterable, Sendable {
    case claude
    case codex

    /// Path of the login file under the home directory of a machine.
    public var remoteRelativePath: String {
        switch self {
        case .claude: ".claude/.credentials.json"
        case .codex: ".codex/auth.json"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// One copy of a login file, with the moment it was last refreshed.
public struct AssistantLogin: Sendable, Equatable {
    public let kind: AssistantLoginKind
    public let data: Data
    /// Seconds since 1970. A copy with a higher value is the newer one.
    public let freshness: TimeInterval

    /// Nil when the bytes are not a login of this kind (no JSON, no token).
    public init?(kind: AssistantLoginKind, data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let freshness = Self.freshness(of: object, kind: kind) else { return nil }
        self.kind = kind
        self.data = data
        self.freshness = freshness
    }

    private static func freshness(of object: [String: Any], kind: AssistantLoginKind) -> TimeInterval? {
        switch kind {
        case .claude:
            guard let oauth = object["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
            let expiresAtMilliseconds = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            return expiresAtMilliseconds / 1000
        case .codex:
            guard let tokens = object["tokens"] as? [String: Any], !tokens.isEmpty else { return nil }
            guard let refreshed = object["last_refresh"] as? String else { return 0 }
            return Self.parseISO8601(refreshed) ?? 0
        }
    }

    private static func parseISO8601(_ text: String) -> TimeInterval? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date.timeIntervalSince1970 }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)?.timeIntervalSince1970
    }

    /// What to do with the two copies of one login.
    public enum Decision: Equatable, Sendable {
        /// Send the Mac's copy to the machine.
        case push
        /// Take the machine's copy on the Mac.
        case pull
        case none
    }

    /// The newest copy wins. Equal bytes need nothing; equal freshness with
    /// different bytes goes the Mac's way.
    public static func decide(local: AssistantLogin?, remote: AssistantLogin?) -> Decision {
        switch (local, remote) {
        case (nil, nil): return .none
        case (nil, .some): return .pull
        case (.some, nil): return .push
        case (.some(let local), .some(let remote)):
            if local.data == remote.data { return .none }
            return remote.freshness > local.freshness ? .pull : .push
        }
    }
}

/// Where the Mac keeps each login.
public protocol LocalLoginStore: Sendable {
    func read(_ kind: AssistantLoginKind) async -> Data?
    func write(_ kind: AssistantLoginKind, data: Data) async throws
    /// The `oauthAccount` block of `~/.claude.json`: who the Claude login is,
    /// shown by Claude and used for its feature flags.
    func claudeAccount() async -> [String: Any]?
}

/// Keychain for Claude, files for the rest, as the assistants do on a Mac.
public struct MacLoginStore: LocalLoginStore {
    public static let keychainService = "Claude Code-credentials"
    private let home: String
    private let account: String

    public init(home: String = NSHomeDirectory(), account: String = NSUserName()) {
        self.home = home
        self.account = account
    }

    public func read(_ kind: AssistantLoginKind) async -> Data? {
        switch kind {
        case .claude:
            let result = try? await ShellCommand.run(
                "/usr/bin/security",
                arguments: ["find-generic-password", "-s", Self.keychainService, "-a", account, "-w"],
                timeout: 20)
            if let result, result.succeeded {
                let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text.data(using: .utf8) }
            }
            return FileManager.default.contents(atPath: "\(home)/\(kind.remoteRelativePath)")
        case .codex:
            return FileManager.default.contents(atPath: "\(home)/\(kind.remoteRelativePath)")
        }
    }

    public func write(_ kind: AssistantLoginKind, data: Data) async throws {
        switch kind {
        case .claude:
            guard let text = String(data: data, encoding: .utf8) else { return }
            let result = try await ShellCommand.run(
                "/usr/bin/security",
                arguments: ["add-generic-password", "-U", "-s", Self.keychainService, "-a", account, "-w", text],
                timeout: 20)
            guard result.succeeded else {
                throw NSError(domain: "MacLoginStore", code: Int(result.exitCode),
                              userInfo: [NSLocalizedDescriptionKey: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)])
            }
        case .codex:
            let path = "\(home)/\(kind.remoteRelativePath)"
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    public func claudeAccount() async -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: "\(home)/.claude.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["oauthAccount"] as? [String: Any]
    }
}

/// Brings the logins of one machine and the Mac to the same copy.
public struct AssistantLoginSync: Sendable {
    public struct Change: Equatable, Sendable {
        public let kind: AssistantLoginKind
        public let decision: AssistantLogin.Decision
    }

    private let runner: any RemoteCommandRunner
    private let store: any LocalLoginStore
    private let remoteHome: String

    public init(runner: any RemoteCommandRunner, store: any LocalLoginStore, remoteHome: String) {
        self.runner = runner
        self.store = store
        self.remoteHome = remoteHome
    }

    /// One command reads every login file of the machine, one line each,
    /// base64 so the JSON never meets the shell.
    public static func readScript(remoteHome: String) -> String {
        let paths = AssistantLoginKind.allCases.map { "\(remoteHome)/\($0.remoteRelativePath)" }
        return "for f in " + paths.map(BoxdMachineSupervisor.shellEscape).joined(separator: " ")
            + "; do if [ -f \"$f\" ]; then base64 -w0 \"$f\"; fi; echo; done"
    }

    /// Merges the Mac's `oauthAccount` into the machine's `~/.claude.json`.
    public static func accountScript(account: [String: Any], claudeConfigPath: String) -> String {
        let accountJSON = (try? JSONSerialization.data(withJSONObject: account, options: [.withoutEscapingSlashes, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let pathJSON = (try? JSONSerialization.data(withJSONObject: [claudeConfigPath], options: .withoutEscapingSlashes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        const fs = require('fs');
        const file = \(pathJSON)[0];
        let config = {};
        try { config = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) {}
        config.oauthAccount = \(accountJSON);
        fs.writeFileSync(file, JSON.stringify(config, null, 2));
        """
    }

    /// Returns the logins that moved, in either direction.
    public func run() async -> [Change] {
        guard let result = try? await runner.exec(["bash", "-c", Self.readScript(remoteHome: remoteHome)], stdin: nil, cwd: nil, timeout: 30),
              result.succeeded else { return [] }
        let lines = result.stdout.components(separatedBy: "\n")
        var changes: [Change] = []
        for (index, kind) in AssistantLoginKind.allCases.enumerated() {
            let line = index < lines.count ? lines[index].trimmingCharacters(in: .whitespaces) : ""
            let remote = line.isEmpty ? nil : Data(base64Encoded: line).flatMap { AssistantLogin(kind: kind, data: $0) }
            let local = await store.read(kind).flatMap { AssistantLogin(kind: kind, data: $0) }
            let decision = AssistantLogin.decide(local: local, remote: remote)
            let remotePath = "\(remoteHome)/\(kind.remoteRelativePath)"
            do {
                switch decision {
                case .none:
                    continue
                case .push:
                    guard let local else { continue }
                    try await runner.put(path: remotePath, data: local.data, mode: 0o600)
                    if kind == .claude, let account = await store.claudeAccount() {
                        let script = Self.accountScript(account: account, claudeConfigPath: "\(remoteHome)/.claude.json")
                        _ = try? await runner.exec(["/usr/local/bin/node", "-e", script], stdin: nil, cwd: nil, timeout: 30)
                    }
                case .pull:
                    guard let remote else { continue }
                    try await store.write(kind, data: remote.data)
                }
                changes.append(Change(kind: kind, decision: decision))
            } catch {
                KanbanCodeLog.warn("boxd", "\(kind.displayName) login sync failed: \(error)")
            }
        }
        return changes
    }
}
