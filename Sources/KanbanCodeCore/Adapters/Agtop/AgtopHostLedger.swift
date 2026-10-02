import Foundation

/// The agtop/rush hosts this master started, by agtop id, host pid and the
/// process start time (so a reused pid does not count). The vault releases
/// a card's secrets to a host only when the master can prove it started
/// it: a host anyone could start with a card's session id and `--meta
/// kanban_card=...` is not the card.
public actor AgtopHostLedger {
    public struct Entry: Codable, Sendable, Equatable {
        public var agtopId: String
        public var pid: Int
        public var startTime: String?
        public var recordedAt: Date
    }

    public static let shared = AgtopHostLedger(
        path: (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/agtop-hosts.json"))

    public let path: String
    private var entries: [String: Entry]?
    private let startTime: @Sendable (Int) -> String?

    public init(path: String, startTime: @escaping @Sendable (Int) -> String? = ProcessStartTime.of) {
        self.path = path
        self.startTime = startTime
    }

    /// The file did not exist yet: nothing was ever recorded on this machine.
    public var isNew: Bool { !FileManager.default.fileExists(atPath: path) }

    public func record(agtopId: String, pid: Int?) {
        guard let pid, pid > 1 else { return }
        var all = load()
        all[agtopId] = Entry(agtopId: agtopId, pid: pid, startTime: startTime(pid), recordedAt: Date())
        save(all)
    }

    /// Records every host at once (the first run on a machine adopts the
    /// hosts its cards already run).
    public func seed(_ hosts: [(agtopId: String, pid: Int)]) {
        var all = load()
        for h in hosts where h.pid > 1 {
            all[h.agtopId] = Entry(agtopId: h.agtopId, pid: h.pid, startTime: startTime(h.pid), recordedAt: Date())
        }
        save(all)
    }

    public func started(agtopId: String, pid: Int?) -> Bool {
        guard let pid, let entry = load()[agtopId], entry.pid == pid else { return false }
        guard let recorded = entry.startTime else { return true }
        return startTime(pid) == recorded
    }

    private func load() -> [String: Entry] {
        if let entries { return entries }
        var out: [String: Entry] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let list = try? JSONDecoder.vault.decode([Entry].self, from: data) {
            for e in list { out[e.agtopId] = e }
        }
        entries = out
        return out
    }

    private func save(_ all: [String: Entry]) {
        // Hosts stopped long ago drop out after a week.
        let kept = all.filter { Date().timeIntervalSince($0.value.recordedAt) < 7 * 24 * 3600 }
        entries = kept
        guard let data = try? JSONEncoder.vault.encode(kept.values.sorted { $0.agtopId < $1.agtopId }) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

/// When a process started, as an opaque string that changes when its pid
/// is reused.
public enum ProcessStartTime {
    public static func of(_ pid: Int) -> String? {
        #if os(Linux)
        // Field 22 of /proc/<pid>/stat, after the parenthesised command name.
        guard let stat = VaultCallerResolver.readProcFile("/proc/\(pid)/stat"),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 19 ? String(fields[19]) : nil
        #else
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return "\(t.tv_sec).\(t.tv_usec)"
        #endif
    }
}
