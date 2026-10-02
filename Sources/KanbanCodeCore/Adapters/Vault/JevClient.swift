import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What Jev reads to judge a release.
public struct JevReleaseQuestion: Sendable, Equatable {
    public var secret: String
    public var rules: String
    public var command: String
    public var reason: String?
    public var cardTitle: String?
    public var cwd: String?

    public init(secret: String, rules: String, command: String, reason: String?, cardTitle: String?, cwd: String?) {
        self.secret = secret
        self.rules = rules
        self.command = command
        self.reason = reason
        self.cardTitle = cardTitle
        self.cwd = cwd
    }
}

public protocol JevJudging: Sendable {
    /// Nil when Jev could not answer (network, auth, rate limit, timeout).
    func judge(_ question: JevReleaseQuestion) async -> JevVerdict?
}

/// The TypeSafe System One endpoint with one choice question.
public struct JevClient: JevJudging {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    public let apiKey: @Sendable () async -> String?
    public let model: String
    public let timeout: TimeInterval
    public let session: URLSession

    public init(model: String = "jev-latest", timeout: TimeInterval = 20, session: URLSession = .shared,
                apiKey: @escaping @Sendable () async -> String?) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    static let instructions = """
    A secrets vault decides whether to hand one secret to one shell command an AI coding agent is about to run. \
    Read the secret's rules, the exact command, the agent's stated reason and its task title. \
    Allow only when the command plainly needs this secret for work the rules permit. \
    Ask a human when it is plausible but unclear, or the rules say a human must see it. \
    Deny when the command would print, copy, upload or send the secret somewhere the rules do not permit, \
    or uses it for something the rules forbid.
    """

    static let criteria: [String: String] = [
        "allow": "The command clearly needs this secret for a use the rules permit, and nothing in it exposes the value.",
        "ask": "The use may be fine but is unclear, broad, or the rules want a human to look.",
        "deny": "The command exposes the value (echo, cat, env dump, paste, upload, sending it to a third party) or does something the rules forbid.",
    ]

    public static func body(for q: JevReleaseQuestion, model: String) -> [String: Any] {
        var state: [String: Any] = [
            "secret_name": q.secret,
            "secret_rules": q.rules.isEmpty ? "No extra rules: use your judgment about exposure." : q.rules,
            "command": q.command,
        ]
        if let reason = q.reason, !reason.isEmpty { state["agent_reason"] = reason }
        if let title = q.cardTitle, !title.isEmpty { state["task_title"] = title }
        if let cwd = q.cwd, !cwd.isEmpty { state["working_directory"] = cwd }
        return [
            "model": model,
            "state": state,
            "questions": [
                "release": [
                    "type": "choice",
                    "instructions": instructions,
                    "criteria": criteria,
                ] as [String: Any],
            ],
        ]
    }

    /// Reads `answers.release` of a System One response.
    public static func parse(_ data: Data) -> JevVerdict? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let release = answers["release"] as? [String: Any],
              let raw = release["choice"] as? String,
              let choice = JevVerdict.Choice(rawValue: raw.lowercased())
        else { return nil }
        let probabilities = release["probabilities"] as? [String: Any]
        let confidence = (probabilities?[raw] as? Double)
            ?? (release["confidence"] as? Double)
            ?? 0
        return JevVerdict(choice: choice, confidence: confidence)
    }

    public func judge(_ question: JevReleaseQuestion) async -> JevVerdict? {
        guard let key = await apiKey(), !key.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: Self.body(for: question, model: model))
        else { return nil }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return Self.parse(data) }
                if status == 429 || status >= 500, attempt == 0 {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                KanbanCodeLog.warn("vault", "Jev answered HTTP \(status)")
                return nil
            } catch {
                if attempt == 0 { continue }
                KanbanCodeLog.warn("vault", "Jev unreachable: \(error.localizedDescription)")
                return nil
            }
        }
        return nil
    }
}
