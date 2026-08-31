import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("BoxdBridge")
struct BoxdBridgeTests {

    // MARK: - Helpers

    /// Starts a bridge and answers its `hello` wait from the fake channel.
    private func connected(
        machineName: String = "kanban-repo-1",
        home: String = "/home/boxd",
        agentVersion: String = "1.4.0"
    ) async throws -> (BoxdBridge, FakeBridgeChannel) {
        let channel = FakeBridgeChannel()
        let bridge = BoxdBridge(machineName: machineName, channel: channel)
        channel.feed(json: ["type": "hello", "home": home, "agentVersion": agentVersion, "vm": machineName])
        try await bridge.start(helloTimeout: .seconds(5))
        return (bridge, channel)
    }

    /// Reads the next event of a bridge after the `hello` the helper above
    /// already fed, or nil after `limit`.
    private func nextEvent(_ bridge: BoxdBridge, limit: Duration = .seconds(2)) async -> BridgeEvent? {
        await withTaskGroup(of: BridgeEvent?.self) { group in
            group.addTask {
                for await event in await bridge.events {
                    if case .hello = event { continue }
                    return event
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Hello

    @Test("start resolves on hello and records the machine's home and version")
    func startResolvesOnHello() async throws {
        let channel = FakeBridgeChannel()
        let bridge = BoxdBridge(machineName: "kanban-repo-1", channel: channel)
        let collector = Task { () -> [BridgeEvent] in
            var seen: [BridgeEvent] = []
            for await event in await bridge.events {
                seen.append(event)
                break
            }
            return seen
        }

        channel.feed(json: ["type": "hello", "home": "/home/boxd", "agentVersion": "1.4.0", "vm": "kanban-repo-1"])
        try await bridge.start(helloTimeout: .seconds(5))

        #expect(await bridge.connected == true)
        #expect(await bridge.remoteHome == "/home/boxd")
        #expect(await bridge.agentVersion == "1.4.0")
        #expect(await collector.value == [.hello(agentVersion: "1.4.0", home: "/home/boxd", vm: "kanban-repo-1")])
    }

    @Test("start times out when hello never arrives")
    func startTimesOutWithoutHello() async throws {
        let channel = FakeBridgeChannel()
        let bridge = BoxdBridge(machineName: "kanban-repo-1", channel: channel)

        await #expect(throws: BoxdBridgeError.timeout("hello")) {
            try await bridge.start(helloTimeout: .milliseconds(200))
        }
        #expect(await bridge.connected == false)
    }

    // MARK: - exec

    @Test("exec sends the argv and returns the matching exec-result")
    func execRoundTrip() async throws {
        let (bridge, channel) = try await connected()

        async let result = bridge.exec(["git", "status"], stdin: nil, cwd: "/home/boxd/repo", timeout: 5)
        try await waitFor { channel.lastSent(type: "exec") != nil }
        let request = try #require(channel.lastSent(type: "exec"))
        #expect(request["argv"] as? [String] == ["git", "status"])
        #expect(request["cwd"] as? String == "/home/boxd/repo")
        let id = try #require(request["id"] as? String)
        channel.feed(json: ["type": "exec-result", "id": id, "stdout": "clean", "stderr": "warn", "code": 3])

        let value = try await result
        #expect(value.stdout == "clean")
        #expect(value.stderr == "warn")
        #expect(value.exitCode == 3)
        #expect(value.succeeded == false)
    }

    @Test("exec times out when nothing answers")
    func execTimesOut() async throws {
        let (bridge, _) = try await connected()

        await #expect(throws: BoxdBridgeError.timeout("ls -la")) {
            _ = try await bridge.exec(["ls", "-la"], stdin: nil, cwd: nil, timeout: 0.2)
        }
    }

    @Test("exec on a bridge that never connected throws disconnected")
    func execWithoutConnection() async throws {
        let channel = FakeBridgeChannel()
        let bridge = BoxdBridge(machineName: "kanban-repo-1", channel: channel)

        await #expect(throws: BoxdBridgeError.disconnected) {
            _ = try await bridge.exec(["ls"], stdin: nil, cwd: nil, timeout: 1)
        }
    }

    @Test("exec carries stdin when given")
    func execSendsStdin() async throws {
        let (bridge, channel) = try await connected()

        async let result = bridge.exec(["cat"], stdin: "hello", cwd: nil, timeout: 5)
        try await waitFor { channel.lastSent(type: "exec") != nil }
        let request = try #require(channel.lastSent(type: "exec"))
        #expect(request["stdin"] as? String == "hello")
        #expect(request["cwd"] == nil)
        channel.feed(json: ["type": "exec-result", "id": request["id"] as! String, "stdout": "hello"])
        _ = try await result
    }

    @Test("remove runs rm -f on the machine")
    func removeRunsRm() async throws {
        let (bridge, channel) = try await connected()

        async let done: Void = bridge.remove(path: "/home/boxd/x.txt")
        try await waitFor { channel.lastSent(type: "exec") != nil }
        let request = try #require(channel.lastSent(type: "exec"))
        #expect(request["argv"] as? [String] == ["rm", "-f", "/home/boxd/x.txt"])
        channel.feed(json: ["type": "exec-result", "id": request["id"] as! String, "code": 0])
        try await done
    }

    // MARK: - put, watch, reply, ping

    @Test("put sends base64 data, and the mode only when given")
    func putSendsBase64() async throws {
        let (bridge, channel) = try await connected()

        try await bridge.put(path: "/home/boxd/a.txt", data: Data("hi".utf8), mode: nil)
        let plain = try #require(channel.lastSent(type: "put"))
        #expect(plain["path"] as? String == "/home/boxd/a.txt")
        #expect(plain["data"] as? String == Data("hi".utf8).base64EncodedString())
        #expect(plain["mode"] == nil)

        try await bridge.put(path: "/home/boxd/run.sh", data: Data("echo".utf8), mode: 0o755)
        let executable = try #require(channel.lastSent(type: "put"))
        #expect(executable["mode"] as? Int == 0o755)
    }

    @Test("watch sends the roots with their globs and the offsets")
    func watchSendsRoots() async throws {
        let (bridge, channel) = try await connected()

        try await bridge.watch(
            roots: [
                BridgeWatchRoot(path: "/home/boxd/.claude/projects", globs: ["**/*.jsonl"]),
                BridgeWatchRoot(path: "/home/boxd/.kanban-code/hook-events.jsonl"),
            ],
            offsets: ["/home/boxd/.kanban-code/hook-events.jsonl": 120]
        )

        let message = try #require(channel.lastSent(type: "watch"))
        let roots = try #require(message["roots"] as? [[String: Any]])
        #expect(roots.count == 2)
        #expect(roots[0]["path"] as? String == "/home/boxd/.claude/projects")
        #expect(roots[0]["globs"] as? [String] == ["**/*.jsonl"])
        #expect(roots[1]["globs"] as? [String] == [])
        #expect(message["offsets"] as? [String: Int] == ["/home/boxd/.kanban-code/hook-events.jsonl": 120])
    }

    @Test("reply sends a proxy-result with the request id and the exit code")
    func replySendsProxyResult() async throws {
        let (bridge, channel) = try await connected()
        let request = BridgeProxyRequest(id: "p7", argv: ["kanban", "note"])

        try await bridge.reply(to: request, stdout: "done", stderr: "", code: 2)

        let message = try #require(channel.lastSent(type: "proxy-result"))
        #expect(message["id"] as? String == "p7")
        #expect(message["stdout"] as? String == "done")
        #expect(message["stderr"] as? String == "")
        #expect(message["code"] as? Int == 2)
    }

    @Test("ping resolves on pong")
    func pingResolvesOnPong() async throws {
        let (bridge, channel) = try await connected()

        async let done: Void = bridge.ping(timeout: .seconds(5))
        try await waitFor { channel.lastSent(type: "ping") != nil }
        channel.feed(json: ["type": "pong"])
        try await done
    }

    @Test("ping times out when no pong arrives")
    func pingTimesOut() async throws {
        let (bridge, _) = try await connected()

        await #expect(throws: BoxdBridgeError.timeout("ping")) {
            try await bridge.ping(timeout: .milliseconds(200))
        }
    }

    // MARK: - Incoming events

    @Test("A file line decodes with the base64 payload decoded")
    func fileLineDecodes() async throws {
        let (bridge, channel) = try await connected()

        channel.feed(json: [
            "type": "file",
            "path": "/home/boxd/.claude/projects/-home-boxd-repo/s1.jsonl",
            "cwd": "/home/boxd/repo",
            "offset": 40,
            "data": Data("{\"a\":1}\n".utf8).base64EncodedString(),
            "eof": false,
        ])

        #expect(await nextEvent(bridge) == .file(
            path: "/home/boxd/.claude/projects/-home-boxd-repo/s1.jsonl",
            cwd: "/home/boxd/repo",
            offset: 40,
            data: Data("{\"a\":1}\n".utf8),
            eof: false
        ))
    }

    @Test("A file line without offset and eof takes the defaults")
    func fileLineDefaults() async throws {
        let (bridge, channel) = try await connected()

        channel.feed(json: ["type": "file", "path": "/x.jsonl", "data": Data("x".utf8).base64EncodedString()])

        #expect(await nextEvent(bridge) == .file(path: "/x.jsonl", cwd: nil, offset: 0, data: Data("x".utf8), eof: true))
    }

    @Test("A proxy line decodes the env and the images")
    func proxyLineDecodes() async throws {
        let (bridge, channel) = try await connected()

        channel.feed(json: [
            "type": "proxy",
            "id": "p1",
            "argv": ["kanban", "note", "hello"],
            "cwd": "/home/boxd/repo",
            "stdin": "body",
            "env": ["KANBAN_CARD_ID": "card_1"],
            "images": [["name": "shot.png", "base64": Data([0x89, 0x50]).base64EncodedString()]],
        ])

        #expect(await nextEvent(bridge) == .proxy(BridgeProxyRequest(
            id: "p1",
            argv: ["kanban", "note", "hello"],
            cwd: "/home/boxd/repo",
            stdin: "body",
            env: ["KANBAN_CARD_ID": "card_1"],
            images: [BridgeProxyRequest.Image(name: "shot.png", data: Data([0x89, 0x50]))]
        )))
    }

    @Test("A proxy image also decodes from a data field")
    func proxyImageFromDataField() async throws {
        let (bridge, channel) = try await connected()

        channel.feed(json: [
            "type": "proxy",
            "id": "p2",
            "argv": ["kanban"],
            "images": [["name": "a.png", "data": Data([0x01]).base64EncodedString()]],
        ])

        guard case .proxy(let request)? = await nextEvent(bridge) else {
            Issue.record("expected a proxy event")
            return
        }
        #expect(request.images == [BridgeProxyRequest.Image(name: "a.png", data: Data([0x01]))])
        #expect(request.env == [:])
        #expect(request.cwd == nil)
    }

    @Test("removed and activity lines decode")
    func removedAndActivityDecode() async throws {
        let (bridge, channel) = try await connected()
        channel.feed(json: ["type": "removed", "path": "/home/boxd/.claude/projects/-home-boxd-repo/s1.jsonl"])
        #expect(await nextEvent(bridge) == .removed(path: "/home/boxd/.claude/projects/-home-boxd-repo/s1.jsonl"))

        let (other, otherChannel) = try await connected(machineName: "kanban-repo-2")
        otherChannel.feed(json: ["type": "activity", "kind": "hook"])
        #expect(await nextEvent(other) == .activity(kind: "hook"))
    }

    @Test("An activity line with no kind defaults to transcript")
    func activityDefaultKind() async throws {
        let (bridge, channel) = try await connected()

        channel.feed(json: ["type": "activity"])

        #expect(await nextEvent(bridge) == .activity(kind: "transcript"))
    }

    @Test("An unreadable line is ignored, it does not break the bridge")
    func unreadableLineIsIgnored() async throws {
        let (bridge, channel) = try await connected()

        channel.feed("this is not json")
        channel.feed(json: ["type": "activity", "kind": "transcript"])

        #expect(await nextEvent(bridge) == .activity(kind: "transcript"))
        #expect(await bridge.connected == true)
    }

    // MARK: - Disconnect

    @Test("Ending the input stream publishes disconnected and fails a pending exec")
    func finishFailsPendingExec() async throws {
        let channel = FakeBridgeChannel()
        channel.setTerminationReason("exit 1: agent crashed")
        let bridge = BoxdBridge(machineName: "kanban-repo-1", channel: channel)
        channel.feed(json: ["type": "hello", "home": "/home/boxd", "agentVersion": "1.0.0", "vm": "kanban-repo-1"])
        try await bridge.start(helloTimeout: .seconds(5))

        let collector = Task { () -> [BridgeEvent] in
            var seen: [BridgeEvent] = []
            for await event in await bridge.events {
                seen.append(event)
                if case .disconnected = event { break }
            }
            return seen
        }

        let pending = Task { try await bridge.exec(["sleep", "10"], stdin: nil, cwd: nil, timeout: 30) }
        try await waitFor { channel.lastSent(type: "exec") != nil }
        channel.finish()

        await #expect(throws: BoxdBridgeError.disconnected) { _ = try await pending.value }
        #expect(await collector.value.contains(.disconnected(reason: "exit 1: agent crashed")))
        #expect(await bridge.connected == false)
    }

    @Test("stop closes the channel")
    func stopClosesTheChannel() async throws {
        let (bridge, channel) = try await connected()

        await bridge.stop()

        #expect(channel.isClosed)
        await #expect(throws: BoxdBridgeError.disconnected) {
            try await bridge.put(path: "/x", data: Data(), mode: nil)
        }
    }
}

/// Spins until `condition` holds, or gives up. Used where a request is sent
/// from a detached task and the test has to see the line before answering.
func waitFor(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () -> Bool
) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("the condition never became true")
}
