import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("BM25 Search")
struct BM25Tests {

    @Test("Tokenize splits and lowercases")
    func tokenize() {
        let tokens = BM25Scorer.tokenize("Fix the Login Bug in AuthService")
        #expect(tokens.contains("fix"))
        #expect(tokens.contains("login"))
        #expect(tokens.contains("bug"))
        #expect(tokens.contains("authservice"))
        #expect(tokens.contains("the")) // 3 chars >= 2 min length
    }

    @Test("Tokenize strips punctuation")
    func tokenizeStrips() {
        let tokens = BM25Scorer.tokenize("hello, world! foo_bar")
        #expect(tokens.contains("hello"))
        #expect(tokens.contains("world"))
        #expect(tokens.contains("foo"))
        #expect(tokens.contains("bar"))
    }

    @Test("Score returns zero for no matching terms")
    func noMatch() {
        let score = BM25Scorer.score(
            terms: ["xyz"],
            documentTokens: ["hello", "world"],
            avgDocLength: 10,
            docCount: 5,
            docFreqs: ["hello": 3, "world": 2]
        )
        #expect(score == 0)
    }

    @Test("Score returns positive for matching terms")
    func match() {
        let score = BM25Scorer.score(
            terms: ["hello"],
            documentTokens: ["hello", "world", "hello"],
            avgDocLength: 10,
            docCount: 5,
            docFreqs: ["hello": 2, "world": 3]
        )
        #expect(score > 0)
    }

    @Test("Higher term frequency → higher score")
    func higherTF() {
        let score1 = BM25Scorer.score(
            terms: ["hello"],
            documentTokens: ["hello", "world"],
            avgDocLength: 10,
            docCount: 5,
            docFreqs: ["hello": 2]
        )
        let score2 = BM25Scorer.score(
            terms: ["hello"],
            documentTokens: ["hello", "hello", "hello", "world"],
            avgDocLength: 10,
            docCount: 5,
            docFreqs: ["hello": 2]
        )
        #expect(score2 > score1)
    }

    @Test("Rarer terms get higher IDF")
    func rareTermHigherIDF() {
        let commonScore = BM25Scorer.score(
            terms: ["the"],
            documentTokens: ["the", "cat"],
            avgDocLength: 10,
            docCount: 100,
            docFreqs: ["the": 90]
        )
        let rareScore = BM25Scorer.score(
            terms: ["quantum"],
            documentTokens: ["quantum", "cat"],
            avgDocLength: 10,
            docCount: 100,
            docFreqs: ["quantum": 2]
        )
        #expect(rareScore > commonScore)
    }

    @Test("Recency boost for recent file")
    func recencyBoostRecent() {
        let boost = BM25Scorer.recencyBoost(modifiedTime: Date.now)
        #expect(boost >= 1.9) // Should be close to 2.0
    }

    @Test("Recency boost for old file")
    func recencyBoostOld() {
        let boost = BM25Scorer.recencyBoost(modifiedTime: Date.now.addingTimeInterval(-86400 * 60))
        #expect(boost == 1.0)
    }

    @Test("Recency boost decays linearly")
    func recencyBoostDecay() {
        let boost15d = BM25Scorer.recencyBoost(modifiedTime: Date.now.addingTimeInterval(-86400 * 15))
        #expect(boost15d > 1.0 && boost15d < 3.0)
        #expect(abs(boost15d - 2.0) < 0.1) // ~2.0 at 15 days (3x decay over 30 days)
    }

    @Test("Multi-term query scores higher when all terms present")
    func multiTermMatch() {
        let oneTermScore = BM25Scorer.score(
            terms: ["login", "bug"],
            documentTokens: ["login", "page", "form"],
            avgDocLength: 10,
            docCount: 5,
            docFreqs: ["login": 2, "bug": 1]
        )
        let bothTermsScore = BM25Scorer.score(
            terms: ["login", "bug"],
            documentTokens: ["login", "bug", "fix"],
            avgDocLength: 10,
            docCount: 5,
            docFreqs: ["login": 2, "bug": 1]
        )
        #expect(bothTermsScore > oneTermScore)
    }

    @Test("Quoted query is treated as exact phrase")
    func quotedExactPhraseQuery() {
        let query = SessionSearchQuery("\"https://github.com/langwatch/langwatch/pull/4189\"")
        #expect(query.requiresExactMatch)
        #expect(query.exactPhrases.contains("https://github.com/langwatch/langwatch/pull/4189"))
        #expect(query.exactMatchCount(in: "see https://github.com/langwatch/langwatch/pull/4189") > 0)
    }

    @Test("PR number query only exact matches that PR")
    func prNumberExactQuery() {
        let query = SessionSearchQuery("#4189")
        #expect(query.requiresExactMatch)
        #expect(query.exactMatchCount(in: "opened PR #4189") > 0)
        #expect(query.exactMatchCount(in: "https://github.com/langwatch/langwatch/pull/4189") > 0)
        #expect(query.exactMatchCount(in: "opened PR #4190") == 0)
    }

    @Test("Claude search indexes pr-link records")
    func claudeSearchIndexesPRLinkRecords() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-search-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("target.jsonl")
        let other = dir.appendingPathComponent("other.jsonl")
        try """
        {"type":"pr-link","sessionId":"s1","prNumber":4189,"prUrl":"https://github.com/langwatch/langwatch/pull/4189","prRepository":"langwatch/langwatch"}

        """.write(to: target, atomically: true, encoding: .utf8)
        try """
        {"type":"pr-link","sessionId":"s2","prNumber":4190,"prUrl":"https://github.com/langwatch/langwatch/pull/4190","prRepository":"langwatch/langwatch"}

        """.write(to: other, atomically: true, encoding: .utf8)

        let results = try await ClaudeCodeSessionStore().searchSessions(
            query: "#4189",
            paths: [target.path, other.path]
        )
        #expect(results.map(\.sessionPath) == [target.path])
        #expect(results.first?.snippets.first?.contains("4189") == true)
    }
}
