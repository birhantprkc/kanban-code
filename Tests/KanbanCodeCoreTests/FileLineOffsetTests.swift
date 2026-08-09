import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("File line offsets")
struct FileLineOffsetTests {

    private static func withFile(
        _ contents: String, _ body: (FileHandle) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-lines-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try await body(handle)
    }

    private static func records(_ handle: FileHandle) async throws -> [FileLines.Record] {
        var result: [FileLines.Record] = []
        for try await record in handle.blockLineRecords { result.append(record) }
        return result
    }

    @Test("each line is reported at the byte it starts on")
    func offsetsMatchTheBytes() async throws {
        let contents = "alpha\nbeta\ngamma\n"
        try await Self.withFile(contents) { handle in
            let records = try await Self.records(handle)
            #expect(records.map(\.text) == ["alpha", "beta", "gamma"])
            #expect(records.map(\.byteOffset) == [0, 6, 11])
        }
    }

    /// Offsets cannot be added up from the lines that come out, which is why they
    /// are counted during the split: a dropped blank line and a trimmed carriage
    /// return are both bytes nobody downstream ever sees.
    @Test("blank lines and carriage returns still take up space")
    func accountsForDroppedBytes() async throws {
        let contents = "alpha\r\n\nbeta\n"
        try await Self.withFile(contents) { handle in
            let records = try await Self.records(handle)
            #expect(records.map(\.text) == ["alpha", "beta"])
            #expect(records.map(\.byteOffset) == [0, 8])
        }
    }

    @Test("a multi-byte character counts as its bytes")
    func countsUTF8Bytes() async throws {
        let contents = "héllo ⏳\nnext\n"
        try await Self.withFile(contents) { handle in
            let records = try await Self.records(handle)
            #expect(records.map(\.byteOffset) == [0, contents.utf8.count - 5])
        }
    }

    /// The reader fills a buffer and splits it at the last newline it holds, so
    /// the offsets have to survive being carried across that boundary. Counting
    /// the staged block instead of what was consumed loses one byte per read.
    @Test("offsets survive the chunk boundary")
    func survivesChunkBoundaries() async throws {
        let lines = (0..<400).map { "line \($0) with enough text to spread across reads" }
        let contents = lines.joined(separator: "\n") + "\n"
        try await Self.withFile(contents) { handle in
            var expected: [Int] = []
            var running = 0
            for line in lines {
                expected.append(running)
                running += line.utf8.count + 1
            }
            let records = try await Self.records(handle)
            #expect(records.map(\.byteOffset) == expected)
        }
    }

    @Test("a file with no trailing newline still reports its last line")
    func handlesMissingTrailingNewline() async throws {
        try await Self.withFile("alpha\nbeta") { handle in
            let records = try await Self.records(handle)
            #expect(records.map(\.text) == ["alpha", "beta"])
            #expect(records.map(\.byteOffset) == [0, 6])
        }
    }

    @Test("the plain line sequence still reads the same lines")
    func plainLinesUnchanged() async throws {
        try await Self.withFile("alpha\n\nbeta\n") { handle in
            var lines: [String] = []
            for try await line in handle.blockLines { lines.append(line) }
            #expect(lines == ["alpha", "beta"])
        }
    }
}
