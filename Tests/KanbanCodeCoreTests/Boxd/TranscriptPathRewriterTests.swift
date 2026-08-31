import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("TranscriptPathRewriter")
struct TranscriptPathRewriterTests {

    private var remoteToLocal: TranscriptPathRewriter {
        TranscriptPathRewriter([
            PathMapping(from: "/home/boxd", to: "/Users/me"),
            PathMapping(from: "/home/boxd/.kanban-code", to: "/Users/me/.kanban-code"),
            PathMapping(from: "/home/boxd/langwatch", to: "/Users/me/Projects/langwatch"),
        ])
    }

    private func field(_ line: String, _ key: String) throws -> String? {
        let data = Data(line.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?[key] as? String
    }

    // MARK: - Plain paths

    @Test("mapPath maps a prefix and leaves an unmapped path alone")
    func mapPath() {
        let rewriter = remoteToLocal
        #expect(rewriter.mapPath("/home/boxd/langwatch/app.ts") == "/Users/me/Projects/langwatch/app.ts")
        #expect(rewriter.mapPath("/home/boxd/.kanban-code/logs") == "/Users/me/.kanban-code/logs")
        #expect(rewriter.mapPath("/home/boxd") == "/Users/me")
        #expect(rewriter.mapPath("/opt/tools/bin") == "/opt/tools/bin")
    }

    @Test("The longest prefix wins")
    func longestPrefixWins() {
        #expect(remoteToLocal.mapPath("/home/boxd/langwatch") == "/Users/me/Projects/langwatch")
        #expect(remoteToLocal.mapText("/home/boxd/langwatch/x") == "/Users/me/Projects/langwatch/x")
    }

    @Test("A partial segment is not a match")
    func noPartialSegmentMatch() {
        let rewriter = remoteToLocal
        #expect(rewriter.mapPath("/home/boxdx/thing") == "/home/boxdx/thing")
        #expect(rewriter.mapText("/home/boxdx/thing") == "/home/boxdx/thing")
        #expect(rewriter.mapText("/opt/home/boxd/thing") == "/opt/home/boxd/thing")
    }

    // MARK: - Transcript lines

    @Test("cwd is rewritten")
    func rewritesCwd() throws {
        let line = #"{"type":"user","cwd":"/home/boxd/langwatch","sessionId":"abc"}"#
        let rewritten = remoteToLocal.rewriteLine(line)
        #expect(try field(rewritten, "cwd") == "/Users/me/Projects/langwatch")
        #expect(try field(rewritten, "sessionId") == "abc")
    }

    @Test("Escaped slashes in the source line do not stop the rewrite")
    func escapedSlashes() throws {
        let line = #"{"cwd":"\/home\/boxd\/langwatch"}"#
        let rewritten = remoteToLocal.rewriteLine(line)
        #expect(try field(rewritten, "cwd") == "/Users/me/Projects/langwatch")
    }

    @Test("Paths nested in a tool_use input are rewritten")
    func nestedToolInput() throws {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/home/boxd/langwatch/src/app.ts","limit":10}}]}}
        """#
        let rewritten = remoteToLocal.rewriteLine(line)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [String: Any])
        let message = try #require(object["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        let input = try #require(content[0]["input"] as? [String: Any])
        #expect(input["file_path"] as? String == "/Users/me/Projects/langwatch/src/app.ts")
        #expect(input["limit"] as? Int == 10)
    }

    @Test("Every element of an array of paths is rewritten")
    func arrayOfPaths() throws {
        let line = #"{"paths":["/home/boxd/a","/home/boxd/.kanban-code/b","/elsewhere/c"]}"#
        let rewritten = remoteToLocal.rewriteLine(line)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [String: Any])
        #expect(object["paths"] as? [String] == ["/Users/me/a", "/Users/me/.kanban-code/b", "/elsewhere/c"])
    }

    @Test("A path inside a longer string is rewritten")
    func insideLongerString() throws {
        let line = #"{"text":"run: cd /home/boxd/langwatch && pnpm test (see \"/home/boxd/notes.md\")"}"#
        let rewritten = remoteToLocal.rewriteLine(line)
        let text = try #require(try field(rewritten, "text"))
        #expect(text.contains("cd /Users/me/Projects/langwatch && pnpm test"))
        #expect(text.contains("\"/Users/me/notes.md\""))
        #expect(!text.contains("/home/boxd"))
    }

    @Test("A non-JSON line comes back untouched")
    func nonJSONPassthrough() {
        let line = "not json at all /home/boxd/langwatch"
        #expect(remoteToLocal.rewriteLine(line) == line)
        #expect(remoteToLocal.rewriteLine("") == "")
    }

    @Test("A line with no mapped path comes back byte for byte")
    func unchangedLineIsNotReserialised() {
        let line = #"{"b":1,"a":"/elsewhere/x"}"#
        #expect(remoteToLocal.rewriteLine(line) == line)
    }

    @Test("A rewriter with no mappings changes nothing")
    func emptyMappings() {
        let rewriter = TranscriptPathRewriter([])
        let line = #"{"cwd":"/home/boxd/langwatch"}"#
        #expect(rewriter.rewriteLine(line) == line)
        #expect(rewriter.mapPath("/home/boxd") == "/home/boxd")
    }

    @Test("The reverse rewriter maps back to the machine paths")
    func reverseIsSymmetric() throws {
        let line = #"{"cwd":"/home/boxd/langwatch","file":"/home/boxd/.kanban-code/context/a.json"}"#
        let local = remoteToLocal.rewriteLine(line)
        let back = remoteToLocal.reversed.rewriteLine(local)
        #expect(try field(back, "cwd") == "/home/boxd/langwatch")
        #expect(try field(back, "file") == "/home/boxd/.kanban-code/context/a.json")
    }

    @Test("A trailing slash in a mapping does not change the result")
    func trailingSlashTolerated() {
        let rewriter = TranscriptPathRewriter([PathMapping(from: "/home/boxd/", to: "/Users/me/")])
        #expect(rewriter.mapPath("/home/boxd/x") == "/Users/me/x")
        #expect(rewriter.mapPath("/home/boxd") == "/Users/me")
    }

    // MARK: - Files

    @Test("A whole transcript file is rewritten line by line")
    func rewritesFile() throws {
        let dir = NSTemporaryDirectory() + "kanban-rewriter-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let source = dir + "/source.jsonl"
        let target = dir + "/nested/target.jsonl"
        let content = [
            #"{"cwd":"/home/boxd/langwatch","n":1}"#,
            "plain text line",
            #"{"cwd":"/home/boxd/.kanban-code","n":2}"#,
        ].joined(separator: "\n") + "\n"
        try content.write(toFile: source, atomically: true, encoding: .utf8)

        try remoteToLocal.rewriteFile(at: source, to: target)

        let written = try String(contentsOfFile: target, encoding: .utf8)
        let lines = written.components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(try field(lines[0], "cwd") == "/Users/me/Projects/langwatch")
        #expect(lines[1] == "plain text line")
        #expect(try field(lines[2], "cwd") == "/Users/me/.kanban-code")
        #expect(lines[3] == "")
    }

    @Test("A file with no trailing newline keeps its last line")
    func rewritesFileWithoutTrailingNewline() throws {
        let dir = NSTemporaryDirectory() + "kanban-rewriter-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let source = dir + "/source.jsonl"
        let target = dir + "/target.jsonl"
        try #"{"cwd":"/home/boxd"}"#.write(toFile: source, atomically: true, encoding: .utf8)

        try remoteToLocal.rewriteFile(at: source, to: target)
        let written = try String(contentsOfFile: target, encoding: .utf8)
        #expect(try field(written, "cwd") == "/Users/me")
    }

    @Test("encodeProjectPath follows the Claude Code encoding")
    func projectPathEncoding() {
        #expect(
            TranscriptPathRewriter.encodeProjectPath("/Users/me/Projects/langwatch")
                == SessionFileMover.encodeProjectPath("/Users/me/Projects/langwatch")
        )
    }
}
