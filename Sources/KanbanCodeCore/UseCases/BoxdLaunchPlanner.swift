import CryptoKit
import Foundation

/// What a resume has to do before the card is back on its machine.
public enum ResumeDecision: String, Sendable, Equatable {
    /// The tmux session is still there, so the app only attaches to it.
    case attach
    /// The local transcript is ahead, so it is pushed before the assistant resumes.
    case pushThenResume
    /// The machine already has the newest transcript, so the assistant resumes as it is.
    case resume
}

/// Pure planning helpers of the boxd remote mode: names, paths, templates and
/// the resume decision. Everything here is a plain function, so the launch flow
/// can be tested without a machine.
public enum BoxdLaunchPlanner {

    /// Longest machine name boxd accepts comfortably as a hostname.
    public static let maximumMachineNameLength = 40
    /// Directories never scanned for files to copy.
    public static let skippedDirectories: Set<String> = [".git", "node_modules"]

    // MARK: - Machine name

    /// Machine name of a card: `kanban-<repo>-<first 8 of the card id>`.
    public static func machineName(repoName: String, cardId: String) -> String {
        let identifier = cardId.hasPrefix("card_") ? String(cardId.dropFirst("card_".count)) : cardId
        let suffix = sanitize(String(identifier.prefix(8)))
        var repository = sanitize(repoName)
        if repository.isEmpty { repository = "repo" }

        let fixedLength = "kanban-".count + 1 + suffix.count
        let room = max(1, maximumMachineNameLength - fixedLength)
        if repository.count > room {
            repository = trimDashes(String(repository.prefix(room)))
            if repository.isEmpty { repository = "repo" }
        }

        let name = suffix.isEmpty ? "kanban-\(repository)" : "kanban-\(repository)-\(suffix)"
        return String(name.prefix(maximumMachineNameLength))
    }

    /// True for a machine this app created: `kanban-<repo>-<card>`. The sweep
    /// only ever touches these.
    public static func isManagedMachineName(_ name: String) -> Bool {
        guard name.hasPrefix("kanban-"), name.count > "kanban-".count else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    // MARK: - Worktree name

    /// Name of a worktree the user left unnamed: a word pair with a short
    /// random suffix, so two unnamed launches on the same repository never
    /// share a branch.
    public static func randomWorktreeName() -> String {
        let adjectives = ["quick", "calm", "bright", "brisk", "keen", "bold", "warm", "swift", "clear", "fresh"]
        let nouns = ["otter", "falcon", "maple", "harbor", "meadow", "comet", "river", "ember", "summit", "willow"]
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).lowercased()
        return "\(adjectives.randomElement()!)-\(nouns.randomElement()!)-\(suffix)"
    }

    /// Lowercases and keeps only `[a-z0-9-]`, with no repeated or edge dashes.
    private static func sanitize(_ value: String) -> String {
        var result = ""
        for character in value.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        return trimDashes(result)
    }

    private static func trimDashes(_ value: String) -> String {
        var result = value
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    // MARK: - Repository name

    /// Repository name of a checkout, from its origin URL when there is one.
    public static func repoName(fromOriginURL originURL: String?, fallbackFolder: String) -> String {
        if let originURL {
            let trimmed = originURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let slug = GhCliAdapter.parseRepoSlug(trimmed), !slug.name.isEmpty {
                    return slug.name
                }
                // A remote the slug parser does not know, for example a plain
                // path or a host the app has never seen. The last component is
                // the repository, as long as the value looks like a location.
                var candidate = trimmed
                if candidate.hasSuffix(".git") { candidate = String(candidate.dropLast(4)) }
                while candidate.hasSuffix("/") { candidate.removeLast() }
                if candidate.contains("/") || candidate.contains(":"),
                   let last = candidate.split(whereSeparator: { $0 == "/" || $0 == ":" }).last,
                   !last.isEmpty, !last.contains("@"),
                   !last.contains(where: { $0.isWhitespace }) {
                    return String(last)
                }
            }
        }
        return folderName(fallbackFolder)
    }

    private static func folderName(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return (trimmed as NSString).lastPathComponent
    }

    // MARK: - Templates

    /// Replaces every `${key}` of a template with its value.
    public static func expand(template: String, values: [String: String]) -> String {
        var result = template
        for key in values.keys.sorted(by: { $0.count > $1.count }) {
            guard let value = values[key] else { continue }
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return result
    }

    /// Where the repository lives on the machine.
    public static func remoteProjectPath(folderTemplate: String, repoName: String, remoteHome: String) -> String {
        let home = trimTrailingSlash(remoteHome)
        var path = expand(template: folderTemplate, values: ["repo_name": repoName]).trimmingCharacters(in: .whitespaces)
        if path.isEmpty { path = repoName }

        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            path = home + "/" + path
        }
        return trimTrailingSlash(path)
    }

    /// The shell snippet that prepares the checkout on the machine.
    public static func initScript(
        template: String,
        repoDir: String,
        repoURL: String,
        repoName: String,
        branch: String
    ) -> String {
        expand(template: template, values: [
            "repo_dir": repoDir,
            "repo_url": repoURL,
            "repo_name": repoName,
            "branch": branch,
        ])
    }

    // MARK: - Path mappings

    /// Machine → Mac mappings, longest prefix first: the project, the Kanban
    /// Code home and finally the home directory.
    public static func mappings(
        localProjectPath: String,
        remoteProjectPath: String,
        localHome: String,
        remoteHome: String,
        localKanbanHome: String,
        remoteKanbanHome: String
    ) -> [PathMapping] {
        [
            PathMapping(from: remoteProjectPath, to: localProjectPath),
            PathMapping(from: remoteKanbanHome, to: localKanbanHome),
            PathMapping(from: remoteHome, to: localHome),
        ]
    }

    // MARK: - Files to copy

    /// Relative paths under `projectRoot` that match one of the glob lines.
    /// `.git` and `node_modules` are never walked.
    /// Files under the project that match the copy globs. The candidates
    /// come from `git status`, which lists untracked and ignored files and
    /// collapses ignored directories such as `node_modules`, so a large
    /// checkout answers in a second or two. A tracked file is in the clone
    /// on the machine already. A folder that is not a repository is walked.
    public static func copyMatches(globs: [String], projectRoot: String) async -> [String] {
        let patterns = globs
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !patterns.isEmpty else { return [] }
        let root = trimTrailingSlash(projectRoot)
        if let candidates = await gitUntrackedAndIgnored(root: root) {
            return candidates
                .filter { relative in patterns.contains(where: { matches(glob: $0, path: relative) }) }
                .sorted()
        }
        return walkMatches(patterns: patterns, root: root)
    }

    /// Untracked (`??`) and ignored (`!!`) files of a checkout, relative to
    /// its root; nil when the folder is not a git repository.
    static func gitUntrackedAndIgnored(root: String) async -> [String]? {
        // `matching` lists an ignored file on its own and an ignored folder
        // as one entry with nothing under it. An untracked folder that
        // still comes collapsed is walked here.
        let arguments = ["-C", root, "status", "--porcelain", "--ignored=matching", "--untracked-files=all", "-z"]
        guard let result = try? await ShellCommand.run("/usr/bin/git", arguments: arguments, timeout: 120),
              result.succeeded else { return nil }
        var files: [String] = []
        var tokens = result.stdout.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let token = tokens.next() {
            guard token.count > 3 else { continue }
            let status = token.prefix(2)
            let path = String(token.dropFirst(3))
            // A rename or copy carries its source path as the next token.
            if status.first == "R" || status.first == "C" { _ = tokens.next() }
            guard status == "??" || status == "!!" else { continue }
            if path.hasSuffix("/") {
                guard status == "??" else { continue }
                let folder = String(path.dropLast())
                files.append(contentsOf: walkFiles(root: "\(root)/\(folder)").map { "\(folder)/\($0)" })
            } else {
                files.append(path)
            }
        }
        return files
    }

    /// Every file under `root`, relative to it, skipping the folders never
    /// copied.
    static func walkFiles(root: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.producesRelativePathURLs]
        ) else { return [] }
        var files: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            files.append(url.relativePath)
        }
        return files
    }

    static func walkMatches(patterns: [String], root: String) -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.producesRelativePathURLs]
        ) else { return [] }

        var found: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if skippedDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let relative = url.relativePath
            if patterns.contains(where: { matches(glob: $0, path: relative) }) {
                found.append(relative)
            }
        }
        return found.sorted()
    }

    /// Glob matching with `**` for any number of directories, `*` inside one
    /// segment and `?` for a single character.
    public static func matches(glob: String, path: String) -> Bool {
        var pattern = glob
        if pattern.hasPrefix("./") { pattern = String(pattern.dropFirst(2)) }
        if pattern.hasPrefix("/") { pattern = String(pattern.dropFirst()) }
        var value = path
        if value.hasPrefix("./") { value = String(value.dropFirst(2)) }
        if value.hasPrefix("/") { value = String(value.dropFirst()) }

        let patternSegments = pattern.split(separator: "/").map(String.init)
        let pathSegments = value.split(separator: "/").map(String.init)
        return matchSegments(patternSegments, 0, pathSegments, 0)
    }

    private static func matchSegments(_ pattern: [String], _ i: Int, _ path: [String], _ j: Int) -> Bool {
        if i == pattern.count { return j == path.count }
        if pattern[i] == "**" {
            // `**` stands for zero or more directories.
            for skipped in j...path.count where matchSegments(pattern, i + 1, path, skipped) {
                return true
            }
            return false
        }
        guard j < path.count, matchSegment(Array(pattern[i]), 0, Array(path[j]), 0) else { return false }
        return matchSegments(pattern, i + 1, path, j + 1)
    }

    private static func matchSegment(_ pattern: [Character], _ i: Int, _ value: [Character], _ j: Int) -> Bool {
        if i == pattern.count { return j == value.count }
        switch pattern[i] {
        case "*":
            for skipped in j...value.count where matchSegment(pattern, i + 1, value, skipped) {
                return true
            }
            return false
        case "?":
            guard j < value.count else { return false }
            return matchSegment(pattern, i + 1, value, j + 1)
        default:
            guard j < value.count, pattern[i] == value[j] else { return false }
            return matchSegment(pattern, i + 1, value, j + 1)
        }
    }

    // MARK: - Resume

    /// What the app has to do to bring a card back on its machine. The
    /// transcripts are compared by lines: the path rewrite changes the byte
    /// size of a copy, the number of lines stays.
    public static func resumeDecision(
        tmuxAlive: Bool,
        localTranscriptLines: Int,
        remoteTranscriptLines: Int
    ) -> ResumeDecision {
        if tmuxAlive { return .attach }
        return localTranscriptLines > remoteTranscriptLines ? .pushThenResume : .resume
    }

    /// Byte length and SHA-256 of the first `lineCount` lines of a file,
    /// read in blocks. Nothing when the file holds fewer lines.
    public static func transcriptPrefix(fileAt path: String, lineCount: Int) -> (bytes: Int, sha256: String)? {
        guard lineCount > 0, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = lineCount
        var bytes = 0
        while let block = try? handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            for (index, byte) in block.enumerated() where byte == 0x0a {
                remaining -= 1
                if remaining == 0 {
                    let cut = block.prefix(index + 1)
                    hasher.update(data: cut)
                    bytes += cut.count
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    return (bytes, digest)
                }
            }
            hasher.update(data: block)
            bytes += block.count
        }
        return nil
    }

    /// The number of newline characters in a file, read in blocks.
    public static func lineCount(ofFileAt path: String) -> Int {
        guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? handle.close() }
        var count = 0
        while let block = try? handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            count += block.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) }
        }
        return count
    }

    // MARK: - Private

    private static func trimTrailingSlash(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
