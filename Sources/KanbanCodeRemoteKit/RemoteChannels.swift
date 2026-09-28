import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Commands run on another master

/// POST /v1/cli: a `kanban channel ...` or `kanban dm ...` command another
/// master hands to the channels home, which runs its own CLI with it.
public struct RemoteCLIRequest: Codable, Sendable, Equatable {
    public struct Image: Codable, Sendable, Equatable {
        public var name: String
        public var base64: String

        public init(name: String, base64: String) {
            self.name = name
            self.base64 = base64
        }
    }

    public var id: String
    public var argv: [String]
    public var cwd: String?
    public var stdin: String?
    /// Only `KANBAN_CARD_ID` (the card the command speaks for) and
    /// `KANBAN_HUMAN_HANDLE` (the user's handle on the calling master) are used.
    public var env: [String: String]?
    /// Files the arguments point at as `.../images/proxy/<id>/<name>`.
    public var images: [Image]?

    public init(id: String = UUID().uuidString.lowercased(), argv: [String], cwd: String? = nil, stdin: String? = nil,
                env: [String: String]? = nil, images: [Image]? = nil) {
        self.id = id
        self.argv = argv
        self.cwd = cwd
        self.stdin = stdin
        self.env = env
        self.images = images
    }
}

public struct RemoteCLIResult: Codable, Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var code: Int

    public init(stdout: String, stderr: String, code: Int) {
        self.stdout = stdout
        self.stderr = stderr
        self.code = code
    }
}

// MARK: - Channel files

/// One file of the channels home's `channels/` directory, as
/// `GET /v1/channels/files` lists it.
public struct RemoteChannelFile: Codable, Sendable, Equatable {
    /// Relative to `channels/`, e.g. `general.jsonl`, `dm/a_b.jsonl`.
    public var path: String
    public var size: Int
    /// Modification time, seconds since 1970.
    public var mtime: Double

    public init(path: String, size: Int, mtime: Double) {
        self.path = path
        self.size = size
        self.mtime = mtime
    }
}

public struct RemoteChannelFiles: Codable, Sendable, Equatable {
    public var files: [RemoteChannelFile]

    public init(files: [RemoteChannelFile]) {
        self.files = files
    }
}

// MARK: - Queue edits

/// PATCH /v1/cards/{id}/queue/{promptId}: new text for a queued prompt.
public struct RemoteQueuedPromptEdit: Codable, Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

extension RemoteClient {
    /// POST /v1/cli
    public func runCLI(_ request: RemoteCLIRequest) async throws -> RemoteCLIResult {
        var req = makeRequest("POST", "v1/cli", body: request)
        req.timeoutInterval = 120
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
        return try JSONDecoder.remote.decode(RemoteCLIResult.self, from: data)
    }

    /// GET /v1/channels/files
    public func channelFiles() async throws -> [RemoteChannelFile] {
        let (data, response) = try await session.data(for: makeRequest("GET", "v1/channels/files"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
        return try JSONDecoder.remote.decode(RemoteChannelFiles.self, from: data).files
    }

    /// GET /v1/channels/files/{path}?offset=: the file from `offset` on.
    public func channelFile(_ path: String, offset: Int = 0) async throws -> Data {
        var req = makeRequest("GET", "v1/channels/files/\(Self.escapePath(path))",
                              query: [URLQueryItem(name: "offset", value: String(offset))])
        req.timeoutInterval = 120
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
        return data
    }

    /// PUT /v1/channels/files/{path}: creates a file the home does not have
    /// yet (the first pairing copies a master's channels there). Returns
    /// false when the home has it already.
    @discardableResult
    public func seedChannelFile(_ path: String, data body: Data) async throws -> Bool {
        var req = makeRequest("PUT", "v1/channels/files/\(Self.escapePath(path))")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 120
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 409 { return false }
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
        return true
    }

    /// PATCH /v1/cards/{id}/queue/{promptId}
    public func editQueuedPrompt(cardId: String, promptId: String, text: String) async throws {
        let req = makeRequest("PATCH", "v1/cards/\(Self.escape(cardId))/queue/\(Self.escape(promptId))",
                              body: RemoteQueuedPromptEdit(text: text))
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
    }

    static func escapePath(_ path: String) -> String {
        path.split(separator: "/").map { escape(String($0)) }.joined(separator: "/")
    }
}
