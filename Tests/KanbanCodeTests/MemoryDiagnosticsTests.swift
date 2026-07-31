import Foundation
import Testing

@testable import KanbanCode

@Suite("Memory diagnostics session trees")
struct MemoryDiagnosticsTests {
    private func record(_ pid: Int32, _ ppid: Int32, _ rssKB: Int, _ command: String) -> MemoryDiagnostics.ProcessRecord {
        MemoryDiagnostics.ProcessRecord(pid: pid, ppid: ppid, rssKB: rssKB, command: command)
    }

    @Test("Attributes a session's whole process subtree and names the top eater")
    func attributesSubtree() {
        // card-a pane (100) -> claude (101) -> pnpm (102) -> tsgo (103, huge)
        // card-b pane (200) -> claude (201)
        let table = [
            record(100, 1, 4_000, "-zsh"),
            record(101, 100, 300_000, "claude --resume abc"),
            record(102, 101, 50_000, "node pnpm.cjs run typecheck"),
            record(103, 102, 14_000_000, "/x/node_modules/.pnpm/tsgo --noEmit --project ./tsconfig.tsgo.tests.json"),
            record(200, 1, 4_000, "-zsh"),
            record(201, 200, 250_000, "claude --resume def"),
            record(999, 1, 8_000_000, "firefox"),  // unrelated, must not be attributed
        ]
        let trees = MemoryDiagnostics.sessionTrees(
            table: table,
            paneRoots: [("card-a", 100), ("card-b", 200)]
        )

        let expectedCardATotal = 4_000 + 300_000 + 50_000 + 14_000_000
        #expect(trees.count == 2)
        #expect(trees[0].session == "card-a")
        #expect(trees[0].rssKB == expectedCardATotal)
        #expect(trees[0].processCount == 4)
        #expect(trees[0].topCommand.hasPrefix("tsgo"))
        #expect(trees[0].topRssKB == 14_000_000)
        #expect(trees[1].session == "card-b")
        #expect(trees[1].rssKB == 254_000)
    }

    @Test("Aggregates multiple panes of the same session")
    func aggregatesPanes() {
        let table = [
            record(100, 1, 1_000, "-zsh"),
            record(110, 1, 2_000, "-zsh"),
            record(111, 110, 3_000, "vim"),
        ]
        let trees = MemoryDiagnostics.sessionTrees(
            table: table,
            paneRoots: [("card-a", 100), ("card-a", 110)]
        )
        #expect(trees.count == 1)
        #expect(trees[0].rssKB == 6_000)
        #expect(trees[0].processCount == 3)
    }

    @Test("Survives ppid cycles without hanging")
    func survivesCycles() {
        let table = [
            record(100, 101, 1_000, "a"),
            record(101, 100, 2_000, "b"),
        ]
        let trees = MemoryDiagnostics.sessionTrees(table: table, paneRoots: [("card-x", 100)])
        #expect(trees.first?.rssKB == 3_000)
    }

    @Test("shortCommand strips the binary path but keeps arguments")
    func shortCommandStripsPath() {
        let cmd = MemoryDiagnostics.shortCommand("/very/long/path/lib/tsgo --noEmit --project ./tsconfig.json")
        #expect(cmd == "tsgo --noEmit --project ./tsconfig.json")
    }
}
