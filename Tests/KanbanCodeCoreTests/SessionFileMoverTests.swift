import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("SessionFileMover path encoding")
struct SessionFileMoverTests {
    @Test("Encodes a plain project path the way Claude does")
    func encodesPlainPath() {
        #expect(
            SessionFileMover.encodeProjectPath("/Users/foo/Projects/bar")
                == "-Users-foo-Projects-bar"
        )
        #expect(
            SessionFileMover.encodeProjectPath("/Users/foo/.claude/worktrees/bar")
                == "-Users-foo--claude-worktrees-bar"
        )
    }

    @Test("Resolves a symlinked project to its real path before encoding")
    func resolvesSymlink() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kanban-symlink-\(UUID().uuidString)")
        let real = root.appendingPathComponent("nexus")
        let link = root.appendingPathComponent("traffic-machine")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        // Claude encodes the resolved cwd, so both spellings must agree —
        // otherwise the session lands where --resume never looks.
        let viaLink = SessionFileMover.encodeProjectPath(link.path)
        let viaReal = SessionFileMover.encodeProjectPath(real.path)
        #expect(viaLink == viaReal)
        #expect(viaLink.hasSuffix("-nexus"))
    }

    @Test("Resolves the existing prefix of a not-yet-created path")
    func resolvesExistingPrefix() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kanban-symlink-\(UUID().uuidString)")
        let real = root.appendingPathComponent("nexus")
        let link = root.appendingPathComponent("traffic-machine")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let future = link.appendingPathComponent("worktrees/not-created-yet").path
        let resolved = SessionFileMover.resolveSymlinks(future)
        #expect(resolved.hasSuffix("/nexus/worktrees/not-created-yet"))
        #expect(!resolved.contains("traffic-machine"))
    }

    @Test("Leaves an unresolvable path untouched")
    func leavesMissingPathAlone() {
        let path = "/definitely/not/here-\(UUID().uuidString)"
        #expect(SessionFileMover.resolveSymlinks(path) == path)
    }
}
