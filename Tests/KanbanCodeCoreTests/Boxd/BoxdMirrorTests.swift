import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("BoxdMirror")
struct BoxdMirrorTests {

    // MARK: - Fixture

    /// A temporary local home, a fixed remote home and the mappings a boxd
    /// card gets. Every test builds its own so nothing is shared.
    struct Fixture {
        let root: String
        let localHome: String
        let localKanbanHome: String
        let stateDirectory: String
        let localProject: String
        let remoteHome = "/home/boxd"
        let remoteProject = "/home/boxd/repo"
        let now: Date

        init() {
            root = NSTemporaryDirectory() + "boxd-mirror-\(UUID().uuidString)"
            localHome = root + "/home"
            localKanbanHome = localHome + "/.kanban-code"
            stateDirectory = localKanbanHome + "/boxd/kc-repo-1"
            localProject = root + "/work/repo"
            now = Date(timeIntervalSince1970: 1_700_000_000)
            try? FileManager.default.createDirectory(atPath: localProject, withIntermediateDirectories: true)
        }

        var rewriter: TranscriptPathRewriter {
            TranscriptPathRewriter(BoxdLaunchPlanner.mappings(
                localProjectPath: localProject,
                remoteProjectPath: remoteProject,
                localHome: localHome,
                remoteHome: remoteHome,
                localKanbanHome: localKanbanHome,
                remoteKanbanHome: "\(remoteHome)/.kanban-code"
            ))
        }

        func makeMirror() -> BoxdMirror {
            BoxdMirror(
                machineName: "kc-repo-1",
                rewriter: rewriter,
                remoteHome: remoteHome,
                localHome: localHome,
                localKanbanHome: localKanbanHome,
                stateDirectory: stateDirectory,
                now: { now }
            )
        }

        /// Where the mirror must put a transcript of `remoteProject`.
        var localProjectDirectory: String {
            "\(localHome)/.claude/projects/\(TranscriptPathRewriter.encodeProjectPath(localProject))"
        }

        var remoteProjectDirectory: String {
            "\(remoteHome)/.claude/projects/\(BoxdMirror.encodeRemoteProjectPath(remoteProject))"
        }

        func cleanUp() {
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    private func read(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A transcript line that carries a remote path, so the rewriter changes it.
    private func transcriptLine(_ text: String) -> String {
        #"{"cwd":"/home/boxd/repo","type":"user","message":"\#(text)"}"#
    }

    /// A transcript line with no path in it. The rewriter returns it as it
    /// came, so the local byte count matches the remote one and the offset
    /// tests measure the offset rule alone.
    private func plainLine(_ text: String) -> String {
        #"{"type":"user","message":"\#(text)"}"#
    }

    // MARK: - Transcripts

    @Test("A transcript chunk with a cwd is written under the local project and rewritten")
    func transcriptWithCwdIsWritten() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        let payload = Data((transcriptLine("hello") + "\n").utf8)

        let outcome = await mirror.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: 0, data: payload, eof: true))

        let expected = "\(fixture.localProjectDirectory)/s1.jsonl"
        #expect(outcome == .transcript(sessionId: "s1", localPath: expected))
        let written = try #require(read(expected))
        #expect(written.contains("\"cwd\":\"\(fixture.localProject)\""))
        #expect(!written.contains("/home/boxd"))
        #expect(written.hasSuffix("\n"))
    }

    @Test("A transcript chunk with no cwd is buffered and nothing is written")
    func transcriptWithoutCwdIsBuffered() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"

        let outcome = await mirror.apply(.file(path: remotePath, cwd: nil, offset: 0, data: Data("x\n".utf8), eof: true))

        #expect(outcome == .buffered(path: remotePath))
        #expect(FileManager.default.fileExists(atPath: "\(fixture.localProjectDirectory)/s1.jsonl") == false)
        #expect(await mirror.offsets[remotePath] == nil)
    }

    @Test("Buffered bytes are replayed when the path is resumed")
    func bufferedBytesReplayOnResume() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        // The mirror learns the project directory from a first chunk.
        let first = Data((plainLine("one") + "\n").utf8)
        _ = await mirror.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: 0, data: first, eof: true))
        let firstLength = first.count

        await mirror.suspend(remotePath: remotePath)
        let held = Data((plainLine("two") + "\n").utf8)
        let outcome = await mirror.apply(.file(path: remotePath, cwd: nil, offset: firstLength, data: held, eof: true))
        #expect(outcome == .buffered(path: remotePath))

        await mirror.resume(remotePath: remotePath)

        let written = try #require(read("\(fixture.localProjectDirectory)/s1.jsonl"))
        #expect(written.contains("one"))
        #expect(written.contains("two"))
        #expect(await mirror.offsets[remotePath] == firstLength + held.count)
    }

    @Test("Bytes buffered for an unknown cwd are replayed by the next chunk that carries one")
    func bufferedBytesReplayOnNextCwdChunk() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        let first = Data((transcriptLine("one") + "\n").utf8)
        let second = Data((transcriptLine("two") + "\n").utf8)

        #expect(await mirror.apply(.file(path: remotePath, cwd: nil, offset: 0, data: first, eof: true)) == .buffered(path: remotePath))
        _ = await mirror.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: first.count, data: second, eof: true))

        let written = try #require(read("\(fixture.localProjectDirectory)/s1.jsonl"))
        #expect(written.contains("one"))
        #expect(written.contains("two"))
    }

    // MARK: - Offsets

    @Test("Two chunks leave the offset at the total remote byte count")
    func offsetsFollowRemoteBytes() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        let first = Data((plainLine("one") + "\n").utf8)
        let second = Data((plainLine("two") + "\n").utf8)

        _ = await mirror.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: 0, data: first, eof: false))
        _ = await mirror.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: first.count, data: second, eof: true))

        #expect(await mirror.offsets[remotePath] == first.count + second.count)
        let written = try #require(read("\(fixture.localProjectDirectory)/s1.jsonl"))
        #expect(written.contains("one"))
        #expect(written.contains("two"))
    }

    @Test("Offsets survive a new mirror on the same state directory")
    func offsetsPersist() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        let payload = Data((plainLine("one") + "\n").utf8)
        let first = fixture.makeMirror()
        _ = await first.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: 0, data: payload, eof: true))

        let second = fixture.makeMirror()

        #expect(await second.offsets[remotePath] == payload.count)
        // The project directory was persisted too, so a chunk with no cwd
        // now finds its place.
        let more = Data((plainLine("two") + "\n").utf8)
        let outcome = await second.apply(.file(path: remotePath, cwd: nil, offset: payload.count, data: more, eof: true))
        #expect(outcome == .transcript(sessionId: "s1", localPath: "\(fixture.localProjectDirectory)/s1.jsonl"))
    }

    @Test("A chunk at offset zero after data was written starts the local file over")
    func offsetZeroTruncates() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        let first = Data((plainLine("one") + "\n").utf8)
        _ = await mirror.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: 0, data: first, eof: true))

        let rewritten = Data((plainLine("fresh") + "\n").utf8)
        _ = await mirror.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: 0, data: rewritten, eof: true))

        let written = try #require(read("\(fixture.localProjectDirectory)/s1.jsonl"))
        #expect(!written.contains("one"))
        #expect(written.contains("fresh"))
        #expect(await mirror.offsets[remotePath] == rewritten.count)
    }

    @Test("The offset counts remote bytes even when the rewrite changes the length")
    func offsetsStayInRemoteBytes() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        // This line holds the remote project path, so the rewrite makes it longer.
        let payload = Data((transcriptLine("one") + "\n").utf8)

        _ = await mirror.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: 0, data: payload, eof: true))

        #expect(await mirror.offsets[remotePath] == payload.count)
    }

    @Test("seedOffsets only fills paths the mirror does not know")
    func seedOffsetsKeepsWhatItHas() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let known = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        _ = await mirror.apply(.file(path: known, cwd: fixture.remoteProject, offset: 0, data: Data("x\n".utf8), eof: true))

        await mirror.seedOffsets([known: 9999, "\(fixture.remoteProjectDirectory)/old.jsonl": 512])

        #expect(await mirror.offsets[known] == 2)
        #expect(await mirror.offsets["\(fixture.remoteProjectDirectory)/old.jsonl"] == 512)
    }

    // MARK: - Sidecars

    @Test("A sidecar arriving after its transcript is written byte for byte")
    func sidecarFollowsTheTranscript() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let transcript = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        _ = await mirror.apply(.file(path: transcript, cwd: fixture.remoteProject, offset: 0, data: Data((transcriptLine("one") + "\n").utf8), eof: true))

        let sidecar = "\(fixture.remoteProjectDirectory)/s1/tool-results/x.txt"
        let raw = Data("/home/boxd/repo is not rewritten here\n".utf8)
        let outcome = await mirror.apply(.file(path: sidecar, cwd: nil, offset: 0, data: raw, eof: true))

        let expected = "\(fixture.localProjectDirectory)/s1/tool-results/x.txt"
        #expect(outcome == .sidecar(localPath: expected))
        #expect(FileManager.default.contents(atPath: expected) == raw)
    }

    @Test("A sidecar arriving before any transcript is buffered")
    func sidecarWithoutProjectIsBuffered() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let sidecar = "\(fixture.remoteProjectDirectory)/s1/tool-results/x.txt"

        let outcome = await mirror.apply(.file(path: sidecar, cwd: nil, offset: 0, data: Data("x".utf8), eof: true))

        #expect(outcome == .buffered(path: sidecar))
    }

    @Test("A path the mirror does not handle is ignored")
    func unknownPathIsIgnored() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()

        let outcome = await mirror.apply(.file(path: "/home/boxd/repo/README.md", cwd: nil, offset: 0, data: Data("x".utf8), eof: true))

        #expect(outcome == .ignored(path: "/home/boxd/repo/README.md"))
    }

    // MARK: - Hook events

    @Test("Hook events are relayed with local paths, the local time and the machine name")
    func hookEventsAreRelayed() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let transcript = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        let lines = [
            #"{"transcriptPath":"\#(transcript)","cwd":"\#(fixture.remoteProject)","sessionId":"s1","event":"Stop","timestamp":"2020-01-01T00:00:00.000Z"}"#,
            #"{"transcriptPath":"\#(transcript)","cwd":"\#(fixture.remoteProject)","sessionId":"s1","event":"Notification","timestamp":"2020-01-01T00:00:01.000Z"}"#,
        ]
        let payload = Data((lines.joined(separator: "\n") + "\n").utf8)

        let outcome = await mirror.apply(.file(
            path: "\(fixture.remoteHome)/.kanban-code/hook-events.jsonl",
            cwd: nil, offset: 0, data: payload, eof: true
        ))

        #expect(outcome == .hookEvents(count: 2))
        let text = try #require(read("\(fixture.localKanbanHome)/hook-events.jsonl"))
        let objects = text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        #expect(objects.count == 2)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let localTranscript = "\(fixture.localProjectDirectory)/s1.jsonl"
        for object in objects {
            #expect(object["transcriptPath"] as? String == localTranscript)
            #expect(object["cwd"] as? String == fixture.localProject)
            #expect(object["machine"] as? String == "kc-repo-1")
            #expect(object["timestamp"] as? String == formatter.string(from: fixture.now))
        }
        #expect(objects.map { $0["event"] as? String } == ["Stop", "Notification"])
        #expect(await mirror.offsets["\(fixture.remoteHome)/.kanban-code/hook-events.jsonl"] == payload.count)
    }

    @Test("A second hook chunk is appended, not written over")
    func hookEventsAppend() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let path = "\(fixture.remoteHome)/.kanban-code/hook-events.jsonl"
        let first = Data((#"{"sessionId":"s1","event":"Stop"}"# + "\n").utf8)
        let second = Data((#"{"sessionId":"s2","event":"Stop"}"# + "\n").utf8)

        _ = await mirror.apply(.file(path: path, cwd: nil, offset: 0, data: first, eof: true))
        _ = await mirror.apply(.file(path: path, cwd: nil, offset: first.count, data: second, eof: true))

        let text = try #require(read("\(fixture.localKanbanHome)/hook-events.jsonl"))
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.contains("s1"))
        #expect(text.contains("s2"))
    }

    // MARK: - Context files

    @Test("A context file is written under the local kanban home")
    func contextFileIsWritten() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let payload = Data(#"{"cwd":"/home/boxd/repo","tokens":1200}"#.utf8)

        let outcome = await mirror.apply(.file(
            path: "\(fixture.remoteHome)/.kanban-code/context/s1.json",
            cwd: nil, offset: 0, data: payload, eof: true
        ))

        let expected = "\(fixture.localKanbanHome)/context/s1.json"
        #expect(outcome == .context(localPath: expected))
        let written = try #require(read(expected))
        #expect(written.contains(fixture.localProject))
    }

    // MARK: - Path mapping

    @Test("remotePath and localPath are inverses of each other")
    func pathMappingRoundTrip() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let local = "\(fixture.localProjectDirectory)/s1.jsonl"

        let remote = await mirror.remotePath(forLocal: local, remoteCwd: fixture.remoteProject)

        #expect(remote == "\(fixture.remoteProjectDirectory)/s1.jsonl")
        // The call taught the mirror the pairing, so the way back needs no cwd.
        #expect(await mirror.localPath(forRemote: remote!, cwd: nil) == local)
    }

    @Test("Codex session paths map straight across")
    func codexPathsMapDirectly() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remote = "\(fixture.remoteHome)/.codex/sessions/2026/08/29/rollout-s1.jsonl"

        let local = await mirror.localPath(forRemote: remote, cwd: nil)

        #expect(local == "\(fixture.localHome)/.codex/sessions/2026/08/29/rollout-s1.jsonl")
        #expect(await mirror.remotePath(forLocal: local!, remoteCwd: fixture.remoteProject) == remote)
    }

    @Test("encodeRemoteProjectPath replaces slashes and dots without touching this Mac")
    func encodeRemoteProjectPath() {
        #expect(BoxdMirror.encodeRemoteProjectPath("/home/boxd/repo") == "-home-boxd-repo")
        #expect(BoxdMirror.encodeRemoteProjectPath("/home/boxd/my.app/x") == "-home-boxd-my-app-x")
    }

    @Test("watchRoots cover the transcripts, the hook events and the context files")
    func watchRootsCoverEverything() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()

        let roots = await mirror.watchRoots

        #expect(roots.map(\.path) == [
            "/home/boxd/.claude/projects",
            "/home/boxd/.codex/sessions",
            "/home/boxd/.kanban-code/hook-events.jsonl",
            "/home/boxd/.kanban-code/context",
        ])
        #expect(roots[0].globs.contains("**/tool-results/*"))
    }

    // MARK: - Removals

    @Test("removed drops the offset and keeps the local file")
    func removedKeepsTheLocalFile() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        _ = await mirror.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: 0, data: Data((transcriptLine("one") + "\n").utf8), eof: true))
        let local = "\(fixture.localProjectDirectory)/s1.jsonl"

        let outcome = await mirror.apply(.removed(path: remotePath))

        #expect(outcome == .removed(localPath: local))
        #expect(await mirror.offsets[remotePath] == nil)
        #expect(FileManager.default.fileExists(atPath: local))
    }

    @Test("recordPushed marks the bytes the Mac wrote itself")
    func recordPushedSetsTheOffset() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"

        await mirror.recordPushed(remotePath: remotePath, bytes: 4096, localProjectDirectory: fixture.localProjectDirectory)

        #expect(await mirror.offsets[remotePath] == 4096)
        #expect(await mirror.localPath(forRemote: remotePath, cwd: nil) == "\(fixture.localProjectDirectory)/s1.jsonl")
    }

    @Test("forget drops the offsets and the state file")
    func forgetClearsState() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()
        let remotePath = "\(fixture.remoteProjectDirectory)/s1.jsonl"
        _ = await mirror.apply(.file(path: remotePath, cwd: fixture.remoteProject, offset: 0, data: Data("x\n".utf8), eof: true))

        await mirror.forget()

        #expect(await mirror.offsets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.stateDirectory) == false)
    }

    @Test("hello, proxy and activity events are not the mirror's business")
    func nonFileEventsAreNil() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let mirror = fixture.makeMirror()

        #expect(await mirror.apply(.hello(agentVersion: "1", home: "/home/boxd", vm: "kc-repo-1")) == nil)
        #expect(await mirror.apply(.activity(kind: "transcript")) == nil)
        #expect(await mirror.apply(.disconnected(reason: "exit 0")) == nil)
    }
}
