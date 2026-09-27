import Foundation

/// Reads and creates this machine's identity in `~/.kanban-code/machine.json`.
///
/// The id is generated on the first run and never changes afterwards: peers
/// key card ownership on it. The name is only for display and may be edited.
public struct MachineIdentityStore: Sendable {
    public let filePath: String

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.filePath = (base as NSString).appendingPathComponent("machine.json")
    }

    /// The stored identity, or a new one written to disk when there is none
    /// (or the file is unreadable, in which case the broken file is kept as
    /// `machine.json.bkp`).
    public func loadOrCreate(defaultName: String? = nil) -> MachineIdentity {
        if let existing = read() { return existing }
        let fm = FileManager.default
        if fm.fileExists(atPath: filePath) {
            try? fm.removeItem(atPath: filePath + ".bkp")
            try? fm.copyItem(atPath: filePath, toPath: filePath + ".bkp")
        }
        let identity = MachineIdentity(name: defaultName ?? Self.defaultMachineName())
        try? write(identity)
        return identity
    }

    public func read() -> MachineIdentity? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let identity = try? JSONDecoder().decode(MachineIdentity.self, from: data),
              !identity.id.isEmpty
        else { return nil }
        return identity
    }

    public func write(_ identity: MachineIdentity) throws {
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(identity)
        try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }

    /// Renames the machine, keeping its id.
    public func rename(to name: String) throws -> MachineIdentity {
        var identity = loadOrCreate()
        identity.name = name
        try write(identity)
        return identity
    }

    /// The host name without the `.local` mDNS suffix.
    public static func defaultMachineName() -> String {
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name = String(name.dropLast(".local".count)) }
        return name.isEmpty ? "machine" : name
    }
}
