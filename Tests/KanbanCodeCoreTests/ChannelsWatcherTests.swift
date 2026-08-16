import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("ChannelsWatcher")
struct ChannelsWatcherTests {
    private func tmpRoot() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-watcher-\(UUID().uuidString)")
            .path
    }

    /// A small race-safe flag that flips when a specific notification arrives.
    final class NotificationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _fired = false
        private var _name: String?
        var observer: NSObjectProtocol?

        var fired: Bool {
            lock.lock(); defer { lock.unlock() }
            return _fired
        }
        var firedChannelName: String? {
            lock.lock(); defer { lock.unlock() }
            return _name
        }
        func mark(_ name: String? = nil) {
            lock.lock()
            _fired = true
            _name = name
            lock.unlock()
        }
    }

    /// Waits for the flag, poking the trigger again once a second. The
    /// notification travels through the main queue, which the rest of the
    /// suite can starve for seconds when everything runs at once, so the
    /// wait is long and returns the moment the flag flips.
    private func waitFor(
        _ flag: NotificationFlag, seconds: Double, retrigger: (() throws -> Void)? = nil
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        var lastTrigger = Date()
        while Date() < deadline {
            if flag.fired { return }
            try? await Task.sleep(for: .milliseconds(50))
            if let retrigger, Date().timeIntervalSince(lastTrigger) > 1 {
                lastTrigger = Date()
                try? retrigger()
            }
        }
    }

    @Test func channelsFileChangePostsNotification() async throws {
        let base = tmpRoot()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let channelsDir = (base as NSString).appendingPathComponent("channels")
        try FileManager.default.createDirectory(atPath: channelsDir, withIntermediateDirectories: true)
        let path = (channelsDir as NSString).appendingPathComponent("channels.json")
        try #"{"channels":[]}"#.write(toFile: path, atomically: true, encoding: .utf8)

        let flag = NotificationFlag()
        flag.observer = NotificationCenter.default.addObserver(
            forName: .kanbanCodeChannelsChanged,
            object: nil,
            queue: nil
        ) { _ in flag.mark() }
        defer { if let o = flag.observer { NotificationCenter.default.removeObserver(o) } }

        let watcher = ChannelsWatcher(baseDir: base)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(150))

        // Trigger a write.
        let appendNewline = {
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try fh.seekToEnd()
            try fh.write(contentsOf: Data("\n".utf8))
            try fh.close()
        }
        try appendNewline()

        await waitFor(flag, seconds: 10, retrigger: appendNewline)
        #expect(flag.fired, "watcher should have posted .kanbanCodeChannelsChanged")
    }

    @Test func channelLogAppendPostsNotification() async throws {
        let base = tmpRoot()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let channelsDir = (base as NSString).appendingPathComponent("channels")
        try FileManager.default.createDirectory(atPath: channelsDir, withIntermediateDirectories: true)
        let logPath = (channelsDir as NSString).appendingPathComponent("general.jsonl")
        FileManager.default.createFile(atPath: logPath, contents: nil)

        let flag = NotificationFlag()
        flag.observer = NotificationCenter.default.addObserver(
            forName: .kanbanCodeChannelMessagesChanged,
            object: nil,
            queue: nil
        ) { note in
            if let n = note.userInfo?["channelName"] as? String {
                flag.mark(n)
            }
        }
        defer { if let o = flag.observer { NotificationCenter.default.removeObserver(o) } }

        let watcher = ChannelsWatcher(baseDir: base)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(150))

        let line = #"{"id":"m1","ts":"2026-04-18T00:00:00.000Z","from":{"cardId":null,"handle":"user"},"body":"hi","type":"message"}"# + "\n"
        let appendMessage = {
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
            try fh.seekToEnd()
            try fh.write(contentsOf: Data(line.utf8))
            try fh.close()
        }
        try appendMessage()

        await waitFor(flag, seconds: 10, retrigger: appendMessage)
        #expect(flag.fired)
        #expect(flag.firedChannelName == "general")
    }
}
