import Foundation

/// One directory prefix and the directory it becomes.
public struct PathMapping: Sendable, Equatable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = PathMapping.trimTrailingSlash(from)
        self.to = PathMapping.trimTrailingSlash(to)
    }

    /// The same mapping in the other direction.
    public var reversed: PathMapping {
        PathMapping(from: to, to: from)
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

/// Rewrites the paths inside a session transcript from one machine to another.
///
/// A transcript line is a JSON object, and paths appear in many of its fields:
/// `cwd`, tool inputs, tool results, the text of a message. Claude escapes `/`
/// as `\/` in the JSON it writes, so a textual replace over the raw line misses
/// half of them. The rewriter parses the line, walks every string value and
/// replaces the mapped prefixes in the parsed values instead.
///
/// A prefix only matches on a path boundary, so `/home/boxd` never touches
/// `/home/boxdx`. It also matches inside longer strings, so shell output like
/// `cd /home/boxd/langwatch && pnpm test` is mapped as well.
public struct TranscriptPathRewriter: Sendable {
    private let mappings: [PathMapping]

    /// Characters a mapped prefix may start after. A path character before the
    /// prefix means the match is in the middle of another path.
    private static let boundaryBefore: Set<Character> = [
        " ", "\t", "\n", "\r", "\"", "'", "`", "(", ")", "[", "]", "{", "}",
        "<", ">", "=", ":", ",", ";", "|", "&", "@",
    ]

    /// Characters that continue a path segment. A prefix followed by one of
    /// them is a different directory, not the mapped one.
    private static func isSegmentCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "." || character == "_"
            || character == "-" || character == "~" || character == "+"
    }

    public init(_ mappings: [PathMapping]) {
        // Longest prefix first: /home/boxd/repo must win over /home/boxd.
        self.mappings = mappings.sorted { $0.from.count > $1.from.count }
    }

    /// The same rewriter in the other direction.
    public var reversed: TranscriptPathRewriter {
        TranscriptPathRewriter(mappings.map(\.reversed))
    }

    /// The mappings, longest prefix first.
    public var pathMappings: [PathMapping] { mappings }

    // MARK: - Plain paths

    /// Maps a path that is known to be a path, prefix only.
    public func mapPath(_ path: String) -> String {
        for mapping in mappings {
            if path == mapping.from { return mapping.to }
            if path.hasPrefix(mapping.from + "/") {
                return mapping.to + path.dropFirst(mapping.from.count)
            }
        }
        return path
    }

    /// Maps every mapped prefix inside a free-form string.
    public func mapText(_ value: String) -> String {
        guard !mappings.isEmpty, !value.isEmpty else { return value }

        var result = ""
        var index = value.startIndex
        var previous: Character?

        while index < value.endIndex {
            var matched = false
            let startsHere = previous == nil || Self.boundaryBefore.contains(previous!)
            if startsHere {
                for mapping in mappings where value[index...].hasPrefix(mapping.from) {
                    let end = value.index(index, offsetBy: mapping.from.count)
                    let next: Character? = end < value.endIndex ? value[end] : nil
                    if next == nil || next == "/" || !Self.isSegmentCharacter(next!) {
                        result += mapping.to
                        previous = mapping.to.last
                        index = end
                        matched = true
                        break
                    }
                }
            }
            if !matched {
                let character = value[index]
                result.append(character)
                previous = character
                index = value.index(after: index)
            }
        }

        return result
    }

    // MARK: - Transcript lines

    /// Rewrites one `.jsonl` line. A line that is not JSON, or that carries no
    /// mapped path, is returned exactly as it came in.
    public func rewriteLine(_ line: String) -> String {
        guard !mappings.isEmpty else { return line }
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return line }

        var changed = false
        let rewritten = rewriteValue(parsed, changed: &changed)
        guard changed else { return line }

        guard let encoded = try? JSONSerialization.data(
            withJSONObject: rewritten,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        ), let text = String(data: encoded, encoding: .utf8) else {
            return line
        }
        return text
    }

    private func rewriteValue(_ value: Any, changed: inout Bool) -> Any {
        switch value {
        case let text as String:
            let mapped = mapText(text)
            if mapped != text { changed = true }
            return mapped
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            result.reserveCapacity(dictionary.count)
            for (key, nested) in dictionary {
                result[key] = rewriteValue(nested, changed: &changed)
            }
            return result
        case let array as [Any]:
            return array.map { rewriteValue($0, changed: &changed) }
        default:
            return value
        }
    }

    // MARK: - Files

    /// Rewrites a whole transcript file line by line. The file is streamed, so
    /// a hundred-megabyte transcript never has to fit in memory.
    public func rewriteFile(at sourcePath: String, to targetPath: String) throws {
        let fileManager = FileManager.default
        let targetDirectory = (targetPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)

        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourcePath))
        defer { try? input.close() }

        if fileManager.fileExists(atPath: targetPath) {
            try fileManager.removeItem(atPath: targetPath)
        }
        guard fileManager.createFile(atPath: targetPath, contents: nil) else {
            throw TranscriptPathRewriterError.cannotWrite(targetPath)
        }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: targetPath))
        defer { try? output.close() }

        var pending = Data()
        let newline = UInt8(ascii: "\n")

        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            while let position = pending.firstIndex(of: newline) {
                let lineData = pending[pending.startIndex..<position]
                pending = pending[pending.index(after: position)...]
                try output.write(contentsOf: rewritten(lineData) + Data([newline]))
            }
        }
        if !pending.isEmpty {
            try output.write(contentsOf: rewritten(pending))
        }
    }

    private func rewritten(_ lineData: Data) -> Data {
        guard let line = String(data: lineData, encoding: .utf8) else { return Data(lineData) }
        return Data(rewriteLine(line).utf8)
    }

    // MARK: - Project directories

    /// Directory name Claude Code uses for a project path.
    public static func encodeProjectPath(_ projectPath: String) -> String {
        SessionFileMover.encodeProjectPath(projectPath)
    }
}

public enum TranscriptPathRewriterError: Error, LocalizedError {
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .cannotWrite(let path): "Cannot write the rewritten transcript to \(path)"
        }
    }
}
