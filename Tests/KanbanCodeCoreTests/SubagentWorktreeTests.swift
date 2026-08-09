import Foundation
import Testing

@testable import KanbanCodeCore

/// A subagent shares its parent's checkout unless it asks for its own. A
/// worktree per child means a full checkout per child, and a parent that fans
/// out to several of them would pay for every one, so the sharing is the point
/// rather than an oversight.
@Suite("Subagent worktree opt-in")
struct SubagentWorktreeTests {

    @Test("asking for nothing keeps the child in the parent's checkout")
    func noRequestMeansShared() {
        #expect(SubagentWorktree.name(requested: nil, handle: "parser-bug") == nil)
    }

    @Test("asking without a name uses the handle")
    func emptyRequestUsesHandle() {
        #expect(SubagentWorktree.name(requested: "", handle: "parser-bug") == "parser-bug")
        #expect(SubagentWorktree.name(requested: "   ", handle: "parser-bug") == "parser-bug")
    }

    @Test("a name can be given instead")
    func namedRequest() {
        #expect(SubagentWorktree.name(requested: "cache-path", handle: "parser-bug") == "cache-path")
    }

    /// The name becomes both a directory and a branch, so it has to survive both.
    @Test("a name a directory or branch could not carry is slugged")
    func slugsAwkwardNames() {
        #expect(SubagentWorktree.name(requested: "Fix The Parser!", handle: "h") == "fix-the-parser")
        #expect(SubagentWorktree.name(requested: "feature/thing", handle: "h") == "feature-thing")
        #expect(SubagentWorktree.name(requested: "a__b", handle: "h") == "a__b")
    }

    @Test("a name with nothing usable left still produces one")
    func alwaysProducesAName() {
        #expect(SubagentWorktree.name(requested: "!!!", handle: nil) == "subagent")
        #expect(SubagentWorktree.name(requested: "", handle: nil) == "subagent")
    }

    @Test("a very long name is cut to something a branch can hold")
    func boundsLength() {
        let name = SubagentWorktree.name(requested: String(repeating: "a", count: 200), handle: "h")
        #expect(name?.count == 60)
    }

    /// The field is new, so requests written before it exists must still decode.
    @Test("a request without the field decodes as sharing the checkout")
    func decodesWithoutTheField() throws {
        let json = """
        {"id":"1","operation":"spawn","createdAt":"2026-08-09T00:00:00Z","parentCardId":"root"}
        """
        let request = try JSONDecoder().decode(
            SubagentCommandRequest.self, from: Data(json.utf8))
        #expect(request.worktreeName == nil)
    }
}
