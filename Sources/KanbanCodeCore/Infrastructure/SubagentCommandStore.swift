import Foundation

public enum SubagentCommandOperation: String, Codable, Sendable {
    case spawn
    case fork
    case archive
    case resume
}

public struct SubagentCommandRequest: Codable, Sendable, Equatable {
    public let id: String
    public let operation: SubagentCommandOperation
    public let createdAt: String
    public let parentCardId: String
    public let cardId: String?
    public let prompt: String?
    public let assistant: CodingAssistant?
    public let model: String?

    public init(
        id: String,
        operation: SubagentCommandOperation,
        createdAt: String,
        parentCardId: String,
        cardId: String? = nil,
        prompt: String? = nil,
        assistant: CodingAssistant? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.operation = operation
        self.createdAt = createdAt
        self.parentCardId = parentCardId
        self.cardId = cardId
        self.prompt = prompt
        self.assistant = assistant
        self.model = model
    }
}

public struct SubagentCommandResponse: Codable, Sendable, Equatable {
    public let id: String
    public let ok: Bool
    public let cardId: String?
    public let error: String?

    public init(id: String, ok: Bool, cardId: String? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.cardId = cardId
        self.error = error
    }
}

/// Filesystem mailbox used by the CLI to ask the running app to perform
/// stateful subagent operations through BoardStore's serialized reducer.
public actor SubagentCommandStore {
    private let baseURL: URL
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public init(baseURL: URL? = nil, fileManager: FileManager = .default) {
        self.baseURL = baseURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".kanban-code/commands", isDirectory: true)
        self.fileManager = fileManager
    }

    public func pendingRequestIds() throws -> [String] {
        try ensureDirectories()
        return try fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { $0.deletingPathExtension().lastPathComponent }
        .sorted()
    }

    /// Claims a request by atomically moving it out of the inbox. A duplicate
    /// deep link therefore cannot execute the operation twice.
    public func claim(id: String) throws -> SubagentCommandRequest? {
        try ensureDirectories()
        let source = inboxURL.appendingPathComponent("\(id).json")
        let claimed = processingURL.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        guard !fileManager.fileExists(atPath: claimed.path) else { return nil }
        try fileManager.moveItem(at: source, to: claimed)
        do {
            let request = try decoder.decode(SubagentCommandRequest.self, from: Data(contentsOf: claimed))
            guard request.id == id else {
                throw SubagentCommandStoreError.requestIdMismatch(expected: id, actual: request.id)
            }
            return request
        } catch {
            try? fileManager.removeItem(at: claimed)
            throw error
        }
    }

    public func respond(_ response: SubagentCommandResponse) throws {
        try ensureDirectories()
        let finalURL = responsesURL.appendingPathComponent("\(response.id).json")
        let temporaryURL = responsesURL.appendingPathComponent("\(response.id).json.tmp")
        try encoder.encode(response).write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
        try? fileManager.removeItem(at: processingURL.appendingPathComponent("\(response.id).json"))
    }

    private var inboxURL: URL { baseURL.appendingPathComponent("inbox", isDirectory: true) }
    private var processingURL: URL { baseURL.appendingPathComponent("processing", isDirectory: true) }
    private var responsesURL: URL { baseURL.appendingPathComponent("responses", isDirectory: true) }

    private func ensureDirectories() throws {
        for directory in [inboxURL, processingURL, responsesURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

public enum SubagentCommandStoreError: LocalizedError {
    case requestIdMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .requestIdMismatch(let expected, let actual):
            "Subagent command id mismatch: expected \(expected), received \(actual)"
        }
    }
}
