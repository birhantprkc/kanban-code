import Foundation
import Testing

@testable import KanbanCodeCore

/// The transcript is read three different ways: the tail for what is on screen,
/// a full scan for search, and a window around a match to jump to it. They agree
/// on which turn is which only if they agree on how a turn is named, and the
/// search was broken for as long as they did not: the tail numbered turns from
/// the start of the window it happened to load, so a scan's turn 2400 and a
/// tail's turn 2400 were different messages, and usually one of them did not
/// exist.
@Suite("Transcript match offsets")
struct TranscriptMatchOffsetTests {

    private static func line(role: String, text: String) -> String {
        let payload: [String: Any] = [
            "type": role,
            "timestamp": "2026-08-09T12:00:00Z",
            "message": ["role": role, "content": [["type": "text", "text": text]]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    /// Writes a transcript and returns its path plus the byte offset of each line.
    private static func writeTranscript(_ texts: [(role: String, text: String)]) throws -> (
        path: String, offsets: [Int]
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-offsets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("session.jsonl").path

        var body = ""
        var offsets: [Int] = []
        for entry in texts {
            offsets.append(body.utf8.count)
            body += Self.line(role: entry.role, text: entry.text) + "\n"
        }
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return (path, offsets)
    }

    private static func collect(_ path: String, query: String) async -> [Int] {
        var found: [Int] = []
        for await offset in TranscriptReader.scanForMatchOffsets(from: path, query: query) {
            found.append(offset)
        }
        return found
    }

    @Test("a match is reported at the byte offset its line starts on")
    func reportsByteOffsets() async throws {
        let (path, offsets) = try Self.writeTranscript([
            (role: "user", text: "first message"),
            (role: "user", text: "the needle is here"),
            (role: "user", text: "third message"),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(await Self.collect(path, query: "needle") == [offsets[1]])
    }

    /// The whole point of the offset: it is the same number the tail reader gives
    /// a turn, so a match can be found among the turns already on screen.
    @Test("a match offset names the same turn the tail reader loaded")
    func agreesWithTheTailReader() async throws {
        let entries = (0..<40).map { (role: "user", text: "message \($0)") }
            + [(role: "user", text: "the needle is here")]
            + (0..<5).map { (role: "user", text: "after \($0)") }
        let (path, _) = try Self.writeTranscript(entries)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let matches = await Self.collect(path, query: "needle")
        let tail = try await TranscriptReader.readTail(from: path, maxTurns: 20)

        let match = try #require(matches.first)
        let turn = try #require(tail.turns.first { $0.lineNumber == match })
        #expect(turn.textPreview.contains("needle"))
    }

    @Test("a window around a match names its turns the same way")
    func readAroundAgreesWithTheTailReader() async throws {
        let entries = (0..<60).map { (role: "user", text: "message \($0)") }
            + [(role: "user", text: "the needle is here")]
            + (0..<60).map { (role: "user", text: "after \($0)") }
        let (path, _) = try Self.writeTranscript(entries)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let match = try #require(await Self.collect(path, query: "needle").first)
        let around = try await TranscriptReader.readAround(from: path, byteOffset: match)
        let tail = try await TranscriptReader.readTail(from: path, maxTurns: 200)

        let fromWindow = try #require(around.first { $0.lineNumber == match })
        let fromTail = try #require(tail.turns.first { $0.lineNumber == match })
        #expect(fromWindow.textPreview == fromTail.textPreview)
        // Everything the window holds is a turn the tail holds under the same name.
        let tailOffsets = Set(tail.turns.map(\.lineNumber))
        #expect(around.allSatisfy { tailOffsets.contains($0.lineNumber) })
    }

    /// A jump into the middle of a long transcript is the case the window exists
    /// for, so it has to carry what is around the match, not the file.
    @Test("the window is bounded and centred on the match")
    func windowIsBounded() async throws {
        let entries = (0..<200).map { (role: "user", text: "message \($0)") }
            + [(role: "user", text: "the needle is here")]
            + (0..<200).map { (role: "user", text: "after \($0)") }
        let (path, _) = try Self.writeTranscript(entries)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let match = try #require(await Self.collect(path, query: "needle").first)
        let around = try await TranscriptReader.readAround(
            from: path, byteOffset: match, before: 10, after: 10)

        #expect(around.count <= 20)
        #expect(around.contains { $0.lineNumber == match })
        #expect(around.first!.lineNumber < match)
        #expect(around.last!.lineNumber > match)
    }

    @Test("nothing matching yields nothing")
    func noMatches() async throws {
        let (path, _) = try Self.writeTranscript([(role: "user", text: "nothing to see")])
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(await Self.collect(path, query: "needle").isEmpty)
    }

    @Test("case does not have to match")
    func matchesCaseInsensitively() async throws {
        let (path, offsets) = try Self.writeTranscript([(role: "user", text: "The NEEDLE")])
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(await Self.collect(path, query: "needle") == [offsets[0]])
    }
}
