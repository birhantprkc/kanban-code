import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("BoxdCliAdapter")
struct BoxdCliAdapterTests {

    // MARK: - machine get

    @Test("machine get --json decodes")
    func decodesMachineGet() throws {
        let json = """
        {
          "name": "good-wolf",
          "id": "b9d4b448-c9be-4a7a-a93b-e9f20db9511b",
          "status": "running",
          "url": "good-wolf.boxd.sh",
          "ssh": "ssh good-wolf.boxd",
          "public_ip": "152.236.3.40",
          "domains": "-",
          "source": "standalone",
          "auto_suspend": "off",
          "auto_hibernate": "14400s",
          "sharing": "private",
          "networks": "-",
          "isolated": "no"
        }
        """
        let machine = try BoxdCliAdapter.decodeMachine(json)
        #expect(machine.name == "good-wolf")
        #expect(machine.id == "b9d4b448-c9be-4a7a-a93b-e9f20db9511b")
        #expect(machine.status == .running)
        #expect(machine.url == "good-wolf.boxd.sh")
        #expect(machine.source == "standalone")
    }

    // MARK: - machine list

    @Test("machine list --json decodes without an id")
    func decodesMachineList() throws {
        let json = """
        [
          {"name": "good-wolf", "status": "running", "url": "good-wolf.boxd.sh", "source": "standalone", "sharing": "private"},
          {"name": "kanban-langwatch-01ab", "status": "standby", "url": "kanban-langwatch-01ab.boxd.sh", "source": "snapshot/kanban-code-base:v1", "sharing": "private"}
        ]
        """
        let machines = try BoxdCliAdapter.decodeMachines(json)
        #expect(machines.count == 2)
        #expect(machines[0].id == nil)
        #expect(machines[1].status == .standby)
        #expect(machines[1].source == "snapshot/kanban-code-base:v1")
    }

    @Test("An empty list decodes to no machines")
    func decodesEmptyList() throws {
        #expect(try BoxdCliAdapter.decodeMachines("[]").isEmpty)
    }

    // MARK: - machine new

    @Test("machine new --json decodes although it carries no status")
    func decodesMachineNew() throws {
        let json = """
        {"name":"kanban-langwatch-01ab","id":"6f0e...","url":"kanban-langwatch-01ab.boxd.sh","source":"snapshot/kanban-code-base:v1","boot":"1.9s"}
        """
        let machine = try BoxdCliAdapter.decodeMachine(json)
        #expect(machine.name == "kanban-langwatch-01ab")
        #expect(machine.status == .unknown)
        #expect(machine.url == "kanban-langwatch-01ab.boxd.sh")
    }

    // MARK: - snapshots

    @Test("snapshots list --json decodes")
    func decodesSnapshots() throws {
        let json = """
        [{"name":"kanban-code-base","version":"v1","status":"ready","size":"24.3G","used":"0"}]
        """
        let snapshots = try BoxdCliAdapter.decodeSnapshots(json)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].name == "kanban-code-base")
        #expect(snapshots[0].version == "v1")
        #expect(snapshots[0].status == "ready")
        #expect(snapshots[0].size == "24.3G")
    }

    // MARK: - Status mapping

    @Test("Every documented status maps to its case")
    func statusMapping() {
        #expect(BoxdMachineStatus(rawStatus: "running") == .running)
        #expect(BoxdMachineStatus(rawStatus: "booting") == .booting)
        #expect(BoxdMachineStatus(rawStatus: "stopping") == .stopping)
        #expect(BoxdMachineStatus(rawStatus: "standby") == .standby)
        #expect(BoxdMachineStatus(rawStatus: "hibernated") == .hibernated)
        #expect(BoxdMachineStatus(rawStatus: "stopped") == .stopped)
        #expect(BoxdMachineStatus(rawStatus: "destroyed") == .destroyed)
    }

    @Test("A suspended machine reads as standby and an unknown value as unknown")
    func statusFallbacks() {
        #expect(BoxdMachineStatus(rawStatus: "suspended") == .standby)
        #expect(BoxdMachineStatus(rawStatus: "RUNNING") == .running)
        #expect(BoxdMachineStatus(rawStatus: "teleporting") == .unknown)
        #expect(BoxdMachineStatus(rawStatus: "") == .unknown)
    }

    @Test("Only the warm states keep the memory of a machine")
    func keepsMemory() {
        #expect(BoxdMachineStatus.running.keepsMemory)
        #expect(BoxdMachineStatus.standby.keepsMemory)
        #expect(!BoxdMachineStatus.stopped.keepsMemory)
        #expect(!BoxdMachineStatus.hibernated.keepsMemory)
        #expect(!BoxdMachineStatus.destroyed.keepsMemory)
    }

    @Test("An unknown status value does not fail the whole response")
    func toleratesUnknownStatus() throws {
        let machine = try BoxdCliAdapter.decodeMachine(#"{"name":"vm","status":"teleporting"}"#)
        #expect(machine.name == "vm")
        #expect(machine.status == .unknown)
    }

    @Test("Fields of a future CLI version are ignored")
    func toleratesUnknownFields() throws {
        let machine = try BoxdCliAdapter.decodeMachine(#"{"name":"vm","status":"running","brand_new":{"a":1}}"#)
        #expect(machine.name == "vm")
        #expect(machine.status == .running)
        #expect(machine.url == nil)
    }

    @Test("A machine round-trips through JSON")
    func machineRoundTrip() throws {
        let machine = BoxdMachine(name: "vm", id: "id", status: .standby, url: "vm.boxd.sh", source: "standalone")
        let encoded = try JSONEncoder().encode(machine)
        let decoded = try JSONDecoder().decode(BoxdMachine.self, from: encoded)
        #expect(decoded == machine)
    }

    @Test("Output that is not JSON is reported as unreadable")
    func rejectsGarbage() {
        #expect(throws: BoxdError.self) { try BoxdCliAdapter.decodeMachine("boxd: command not found") }
        #expect(throws: BoxdError.self) { try BoxdCliAdapter.decodeMachines("") }
    }

    @Test("The adapter falls back to the bare binary name when boxd is not installed")
    func binaryFallback() async {
        let adapter = BoxdCliAdapter(boxdPath: "/nowhere/boxd")
        // Only the resolution is checked here; no command is run against boxd.
        #expect(await adapter.isAvailable() == (ShellCommand.findExecutable("boxd") != nil))
    }

    // MARK: - Uploads in parts

    @Test("An upload is cut into parts of the configured size, empty data stays one part")
    func uploadParts() {
        let data = Data(repeating: 7, count: 2_500)
        let parts = BoxdCliAdapter.parts(of: data, size: 1_000)
        #expect(parts.map(\.count) == [1_000, 1_000, 500])
        #expect(parts.reduce(Data(), +) == data)
        #expect(BoxdCliAdapter.parts(of: Data(), size: 1_000) == [Data()])
        #expect(BoxdCliAdapter.parts(of: Data(repeating: 1, count: 1_000), size: 1_000).count == 1)
        #expect(BoxdCliAdapter.uploadPartBytes == 4 * 1024 * 1024)
        #expect(BoxdCliAdapter.uploadPartTries == 3)
    }

    @Test("An upload travels gzipped and its progress is reported in the bytes of the payload")
    func uploadCompression() throws {
        let line = Data("{\"type\":\"assistant\",\"message\":{\"content\":\"the same line over and over\"}}\n".utf8)
        var data = Data()
        for _ in 0..<2_000 { data.append(line) }

        let compressed = try #require(BoxdCliAdapter.gzip(data))
        #expect(compressed.count < data.count / 3)
        #expect(Array(compressed.prefix(2)) == [0x1f, 0x8b])

        // The machine unpacks it with gunzip, so the system gunzip must read it back.
        let path = NSTemporaryDirectory() + "kanban-test-\(UUID().uuidString).gz"
        try compressed.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzip.arguments = ["-c", path]
        let out = Pipe()
        gunzip.standardOutput = out
        try gunzip.run()
        let restored = out.fileHandleForReading.readDataToEndOfFile()
        gunzip.waitUntilExit()
        #expect(restored == data)

        #expect(BoxdCliAdapter.gzip(Data())?.isEmpty == false)

        #expect(BoxdCliAdapter.scaled(0, of: 1_000, to: 3_000) == 0)
        #expect(BoxdCliAdapter.scaled(500, of: 1_000, to: 3_000) == 1_500)
        #expect(BoxdCliAdapter.scaled(1_000, of: 1_000, to: 3_000) == 3_000)
        #expect(BoxdCliAdapter.scaled(0, of: 0, to: 0) == 0)
    }

    @Test("A failed command is reported by its reason, not by the command line")
    func shortMessage() {
        let error = BoxdError.commandFailed(
            command: "boxd machine cp /var/folders/x kanban-repo-1:/tmp/kanban-cli.tgz.incoming-1",
            exitCode: 1, message: "error: http2 error\n")
        #expect(BoxdCliAdapter.shortMessage(of: error) == "http2 error")
        #expect(BoxdCliAdapter.shortMessage(of: BoxdError.notInstalled) == "The boxd CLI is not installed")
    }
}
