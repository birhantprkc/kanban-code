import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit

/// Channels and direct messages live on one master, the channels home
/// (`MasterRoles.channelsHome`): an always-on server when one is paired.
/// Its `kanban` CLI and its store write them there. Every other master
/// keeps a read-only mirror of the home's `channels/` directory, so its UI
/// and its CLI read the same channels, and sends its writes to the home:
/// the CLI through `POST /v1/cli`, the UI through the same endpoint.
///
/// `channels-home.json` in the kanban home tells the local CLI where the
/// home is; it exists only while this master is a client of another home.
extension MasterEngine {
    /// Files of `channels/` that stay on each master: what this user read
    /// and typed here.
    nonisolated static let localChannelFiles: Set<String> = ["read-state.json", "drafts.json"]

    nonisolated static func channelsDirectory(home: String) -> String {
        (home as NSString).appendingPathComponent("channels")
    }

    // MARK: Serving (the home)

    /// Runs a `kanban channel|dm ...` command another master handed over,
    /// with this master's CLI and channel data.
    public func runCLI(_ request: RemoteCLIRequest) async -> RemoteCLIResult {
        let command = request.argv.first { !$0.hasPrefix("-") }
        guard let command, ["channel", "dm"].contains(command) else {
            return RemoteCLIResult(stdout: "", stderr: "only `kanban channel` and `kanban dm` run on another master\n", code: 2)
        }
        guard let script = platform.cliScript, let node = platform.nodePath else {
            return RemoteCLIResult(stdout: "", stderr: "the kanban CLI is not installed on this master\n", code: 1)
        }
        let home = platform.kanbanHome
        var argv = request.argv
        if let images = request.images, !images.isEmpty {
            let directory = "\(home)/images/proxy/\((request.id as NSString).lastPathComponent)"
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            var byName: [String: String] = [:]
            for image in images {
                let name = (image.name as NSString).lastPathComponent
                guard let data = Data(base64Encoded: image.base64) else { continue }
                let path = "\(directory)/\(name)"
                try? data.write(to: URL(fileURLWithPath: path))
                byName[name] = path
            }
            argv = argv.map { argument in
                let value = argument.hasPrefix("--image=") ? String(argument.dropFirst("--image=".count)) : argument
                guard value.contains("/images/proxy/"), let local = byName[(value as NSString).lastPathComponent] else {
                    return argument
                }
                return argument.hasPrefix("--image=") ? "--image=\(local)" : local
            }
        }
        var environment = ShellCommand.loginEnvironment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        environment["KANBAN_REMOTE_PROXY"] = nil
        environment["KANBAN_CHANNELS_LOCAL"] = "1"
        environment["KANBAN_CODE_HOME"] = home
        for key in ["KANBAN_CARD_ID", "KANBAN_HUMAN_HANDLE"] {
            if let value = request.env?[key], !value.isEmpty { environment[key] = value } else { environment[key] = nil }
        }
        let cwd = request.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? home
        do {
            let result = try await ShellCommand.run(
                node, arguments: [script] + argv, currentDirectory: cwd,
                stdin: request.stdin, environment: environment, timeout: 110)
            return RemoteCLIResult(stdout: result.stdout, stderr: result.stderr, code: Int(result.exitCode))
        } catch {
            return RemoteCLIResult(stdout: "", stderr: "\(error.localizedDescription)\n", code: 1)
        }
    }

    /// Every shared file of `channels/`, for the masters that mirror it.
    public nonisolated static func listChannelFiles(home: String) -> [RemoteChannelFile] {
        let root = channelsDirectory(home: home)
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root) else { return [] }
        var out: [RemoteChannelFile] = []
        while let relative = walker.nextObject() as? String {
            guard !localChannelFiles.contains(relative), !relative.hasSuffix(".tmp"),
                  !(relative as NSString).lastPathComponent.hasPrefix(".") else { continue }
            let path = (root as NSString).appendingPathComponent(relative)
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.append(RemoteChannelFile(path: relative, size: size, mtime: mtime))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The absolute path of a file of `channels/`, nil for anything that
    /// leaves the directory or is local to a master.
    public nonisolated static func channelFilePath(home: String, relative: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              !localChannelFiles.contains(relative) else { return nil }
        return (channelsDirectory(home: home) as NSString).appendingPathComponent(parts.joined(separator: "/"))
    }

    /// A file of `channels/` from `offset` on.
    public nonisolated static func readChannelFile(home: String, relative: String, offset: Int) throws -> Data {
        guard let path = channelFilePath(home: home, relative: relative),
              let handle = FileHandle(forReadingAtPath: path) else {
            throw RemoteHostError.notFound("no channel file \(relative)")
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(offset, 0)))
        return handle.readDataToEndOfFile()
    }

    /// Creates a file of `channels/` the home does not have. Returns false
    /// when it exists.
    public nonisolated static func seedChannelFile(home: String, relative: String, data: Data) throws -> Bool {
        guard let path = channelFilePath(home: home, relative: relative) else {
            throw RemoteHostError.badRequest("bad channel file path \(relative)")
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { return false }
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let temp = path + ".seed.tmp"
        try data.write(to: URL(fileURLWithPath: temp))
        guard !fm.fileExists(atPath: path) else {
            try? fm.removeItem(atPath: temp)
            return false
        }
        try fm.moveItem(atPath: temp, toPath: path)
        return true
    }

    // MARK: Mirroring (every other master)

    /// Where the local CLI reads the channels home from.
    nonisolated static func channelsHomeFile(home: String) -> String {
        (home as NSString).appendingPathComponent("channels-home.json")
    }

    struct ChannelsHomeInfo: Codable, Equatable {
        var machineId: String
        var name: String
        var url: String
        var token: String
    }

    /// The channels home when it is another master, with the client this
    /// master holds for it.
    public func channelsHomeClient() async -> (status: PeerStatus, client: RemoteClient)? {
        let state = store.state
        guard let local = state.localMachineIdentity,
              let status = MasterRoles.channelsHome(local: local, peers: Array(state.peerStatuses.values)),
              let machineId = status.machine?.id,
              let client = await peerClient(machineId: machineId)
        else { return nil }
        return (status, client)
    }

    /// Where channel writes of this master's UI go while the channels home
    /// is another master.
    public func channelsHomeRoute() async -> ChannelsHomeRoute? {
        guard let (status, client) = await channelsHomeClient() else { return nil }
        let poke = channelsPoke
        return ChannelsHomeRoute(client: client, name: status.machine?.name ?? "the channels home",
                                 poke: { poke.signal() })
    }

    /// Keeps `channels-home.json` and the mirror of the home's channels in
    /// step, every two seconds and at once after `pokeChannelsMirror()`.
    public func runChannelsMirror() async {
        var mirror = ChannelsMirror(home: platform.kanbanHome)
        while !Task.isCancelled {
            await syncChannelsOnce(&mirror)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                group.addTask { [channelsPoke] in await channelsPoke.wait() }
                await group.next()
                group.cancelAll()
            }
        }
    }

    /// Syncs the mirror now (after this master sent a channel write).
    public func pokeChannelsMirror() {
        channelsPoke.signal()
    }

    func syncChannelsOnce(_ mirror: inout ChannelsMirror) async {
        let home = platform.kanbanHome
        let infoPath = Self.channelsHomeFile(home: home)
        guard let (status, client) = await channelsHomeClient(), let machine = status.machine else {
            if FileManager.default.fileExists(atPath: infoPath) { try? FileManager.default.removeItem(atPath: infoPath) }
            channelsHomeName = nil
            return
        }
        channelsHomeName = machine.name
        let info = ChannelsHomeInfo(machineId: machine.id, name: machine.name,
                                    url: client.baseURL.absoluteString, token: client.token)
        let existing = FileManager.default.contents(atPath: infoPath).flatMap { try? JSONDecoder().decode(ChannelsHomeInfo.self, from: $0) }
        if existing != info, let data = try? JSONEncoder().encode(info) {
            try? data.write(to: URL(fileURLWithPath: infoPath), options: .atomic)
        }
        guard status.online else { return }
        do {
            if try await mirror.sync(client: client, homeMachine: machine.id) {
                store.dispatch(.refreshChannels)
                NotificationCenter.default.post(name: .kanbanCodeChannelFilesMirrored, object: nil)
            }
        } catch {
            KanbanCodeLog.warn("channels", "mirror of \(machine.name) failed: \(error.localizedDescription)")
        }
    }
}

/// The channels home as the effect handler reaches it.
public struct ChannelsHomeRoute: Sendable {
    public var client: RemoteClient
    public var name: String
    /// Syncs the local mirror now.
    public var poke: @Sendable () -> Void
}

extension Notification.Name {
    /// The channels mirror wrote files from the channels home.
    public static let kanbanCodeChannelFilesMirrored = Notification.Name("kanbanCodeChannelFilesMirrored")
}

/// A wake-up for a loop that otherwise sleeps: `signal()` before or during
/// `wait()` ends it.
public final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var waiter: CheckedContinuation<Void, Never>?

    public init() {}

    public func signal() {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume()
            return
        }
        pending = true
        lock.unlock()
    }

    public func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if pending {
                    pending = false
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }
    }
}

/// The local copy of the channels home's `channels/` directory. Message
/// logs only grow, so a log that got longer is fetched from where the copy
/// ends; any other change fetches the whole file. The first time a home
/// with no channels at all is seen, this master's channels are copied there.
struct ChannelsMirror {
    let home: String
    /// Remote size and mtime of each file as last written here.
    private var known: [String: RemoteChannelFile] = [:]

    init(home: String) {
        self.home = home
    }

    private var root: String { MasterEngine.channelsDirectory(home: home) }

    private func seededMarker(_ machine: String) -> String {
        (home as NSString).appendingPathComponent("channels-seeded-\(machine)")
    }

    /// Returns whether a local file changed.
    mutating func sync(client: RemoteClient, homeMachine: String) async throws -> Bool {
        let fm = FileManager.default
        var remote = try await client.channelFiles()
        if remote.isEmpty, !fm.fileExists(atPath: seededMarker(homeMachine)) {
            let local = MasterEngine.listChannelFiles(home: home)
            for file in local {
                guard let path = MasterEngine.channelFilePath(home: home, relative: file.path),
                      let data = fm.contents(atPath: path) else { continue }
                try await client.seedChannelFile(file.path, data: data)
            }
            fm.createFile(atPath: seededMarker(homeMachine), contents: Data())
            KanbanCodeLog.info("channels", "copied \(local.count) channel files to the channels home \(homeMachine)")
            remote = try await client.channelFiles()
        }
        if !fm.fileExists(atPath: seededMarker(homeMachine)) {
            fm.createFile(atPath: seededMarker(homeMachine), contents: Data())
        }

        var changed = false
        let remotePaths = Set(remote.map(\.path))
        for file in remote {
            guard let path = MasterEngine.channelFilePath(home: home, relative: file.path) else { continue }
            if known[file.path] == file, fm.fileExists(atPath: path) { continue }
            let localSize = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
            let localMtime = ((try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970
            if localSize == file.size, let localMtime, abs(localMtime - file.mtime) < 0.001 {
                known[file.path] = file
                continue
            }
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if file.path.hasSuffix(".jsonl"), let localSize, localSize > 0, localSize < file.size {
                let tail = try await client.channelFile(file.path, offset: localSize)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try handle.seekToEnd()
                try handle.write(contentsOf: tail)
                try handle.close()
            } else {
                let data = try await client.channelFile(file.path, offset: 0)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: file.mtime)], ofItemAtPath: path)
            known[file.path] = file
            changed = true
        }
        for file in MasterEngine.listChannelFiles(home: home) where !remotePaths.contains(file.path) {
            guard let path = MasterEngine.channelFilePath(home: home, relative: file.path) else { continue }
            try? fm.removeItem(atPath: path)
            known[file.path] = nil
            changed = true
        }
        return changed
    }
}
