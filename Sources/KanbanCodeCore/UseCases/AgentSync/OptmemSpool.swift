import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The memo commands a machine could not forward to the OptMem home while
/// it was unreachable. memo writes each as `<spool>/<nanoseconds>-<id>.json`
/// (an `OptmemRunRequest`); Kanban Code sends them to the home in that
/// order once it answers, and the home numbers the memories.
public struct OptmemSpool: Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    /// `~/.optmem/spool` for the memory at `~/.optmem/memory`.
    public init(optmemRoot: String) {
        self.directory = optmemRoot + "/spool"
    }

    public struct Pending: Sendable, Equatable {
        public var file: String
        public var request: OptmemRunRequest
    }

    public struct Replay: Sendable, Equatable {
        public var sent: Int
        public var remaining: Int
        public var error: String?
    }

    /// Queued commands, oldest first. A file that does not parse is skipped
    /// (and stays for a person to look at).
    public func pending() -> [Pending] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let file = directory + "/" + name
            guard let data = FileManager.default.contents(atPath: file),
                  let request = try? JSONDecoder().decode(OptmemRunRequest.self, from: data)
            else { return nil }
            return Pending(file: file, request: request)
        }
    }

    /// Queues `request` after everything already queued (memo does this in
    /// Python; this twin is for tests and tools).
    @discardableResult
    public func enqueue(_ request: OptmemRunRequest, at date: Date = Date()) throws -> String {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let nanos = UInt64(date.timeIntervalSince1970 * 1_000_000_000)
        let digits = String(nanos)
        let name = String(repeating: "0", count: max(0, 20 - digits.count)) + digits + "-" + request.id + ".json"
        let file = directory + "/" + name
        let tmp = directory + "/." + name + ".tmp"
        try JSONEncoder().encode(request).write(to: URL(fileURLWithPath: tmp))
        guard rename(tmp, file) == 0 else { throw SyncApplyError.failed("cannot queue \(file)") }
        return file
    }

    /// Sends every queued command in order, deleting each once the home
    /// answered it. Stops at the first one the home does not answer, so the
    /// order holds. Another process replaying at the same time makes this a
    /// no-op.
    public func replay(send: @Sendable (OptmemRunRequest) async throws -> OptmemRunResult) async -> Replay {
        let queue = pending()
        guard !queue.isEmpty else { return Replay(sent: 0, remaining: 0) }
        guard let lock = Self.tryLock(directory + "/.lock") else {
            return Replay(sent: 0, remaining: queue.count, error: "another replay is running")
        }
        defer { close(lock) }
        var sent = 0
        for item in pending() {
            let result: OptmemRunResult
            do {
                result = try await send(item.request)
            } catch {
                return Replay(sent: sent, remaining: pending().count, error: error.localizedDescription)
            }
            log(item.request, result)
            try? FileManager.default.removeItem(atPath: item.file)
            sent += 1
        }
        return Replay(sent: sent, remaining: pending().count)
    }

    private func log(_ request: OptmemRunRequest, _ result: OptmemRunResult) {
        let first = (result.stdout + result.stderr).split(separator: "\n").first.map(String.init) ?? ""
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(request.id) \(request.argv.first ?? "") exit \(result.status): \(first)\n"
        let path = directory + "/replayed.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    static func tryLock(_ path: String) -> Int32? {
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return fd
    }
}
