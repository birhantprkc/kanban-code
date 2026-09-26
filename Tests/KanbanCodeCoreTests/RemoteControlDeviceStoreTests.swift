import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Remote device store")
struct RemoteControlDeviceStoreTests {

    private static func path() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("remote-devices-\(UUID().uuidString)/devices.json")
    }

    @Test("tokens are kc_ plus 40 base62 characters")
    func tokenFormat() {
        for _ in 0..<50 {
            let token = RemoteDeviceStore.makeToken()
            #expect(token.hasPrefix("kc_"))
            #expect(token.count == 43)
            #expect(token.dropFirst(3).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        }
    }

    @Test("add, authenticate, list, revoke round trip; the file keeps only the hash")
    func roundTrip() throws {
        let path = Self.path()
        let store = RemoteDeviceStore(path: path)
        let (device, token) = try store.add(name: "iPhone", scope: .full)
        #expect(store.authenticate(token: token)?.id == device.id)
        #expect(store.authenticate(token: token + "x") == nil)
        #expect(store.list().map(\.name) == ["iPhone"])

        let raw = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!raw.contains(token))
        #expect(raw.contains(RemoteDeviceStore.hash(token)))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let entry = try #require((json["devices"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys).isSuperset(of: ["id", "name", "scope", "tokenHash", "createdAt"]))
        #expect((entry["createdAt"] as? String)?.hasSuffix("Z") == true)
        #expect((entry["tokenHash"] as? String)?.count == 64)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        #expect(try store.revoke(id: device.id))
        #expect(store.authenticate(token: token) == nil)
        #expect(try store.revoke(id: device.id) == false)
    }

    @Test("a change written by another process is picked up")
    func externalChange() throws {
        let path = Self.path()
        let app = RemoteDeviceStore(path: path)
        let cli = RemoteDeviceStore(path: path)
        #expect(app.list().isEmpty)
        let (device, token) = try cli.add(name: "openclaw", scope: .agent)
        #expect(app.authenticate(token: token)?.scope == .agent)
        try cli.revoke(id: device.id)
        #expect(app.authenticate(token: token) == nil)
    }

    @Test("reads a file written by hand in the documented format")
    func handWritten() throws {
        let path = Self.path()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let token = "kc_" + String(repeating: "a", count: 40)
        let json = """
        {"devices":[{"id":"d1","name":"cli","scope":"agent","tokenHash":"\(RemoteDeviceStore.hash(token))","createdAt":"2026-09-26T10:00:00.000Z"}]}
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        let store = RemoteDeviceStore(path: path)
        let device = try #require(store.authenticate(token: token))
        #expect(device.id == "d1")
        #expect(device.lastSeenAt != nil)
    }

    @Test("lastSeenAt is written at most once a minute")
    func lastSeenThrottle() throws {
        let store = RemoteDeviceStore(path: Self.path())
        let (_, token) = try store.add(name: "iPhone", scope: .full)
        let first = try #require(store.authenticate(token: token)?.lastSeenAt)
        let second = try #require(store.authenticate(token: token)?.lastSeenAt)
        #expect(first == second)
    }

    @Test("tailscale ranges")
    func tailscaleRanges() {
        #expect(RemoteNetworkAddresses.isTailscaleV4([100, 64, 0, 1]))
        #expect(RemoteNetworkAddresses.isTailscaleV4([100, 127, 255, 255]))
        #expect(!RemoteNetworkAddresses.isTailscaleV4([100, 128, 0, 1]))
        #expect(!RemoteNetworkAddresses.isTailscaleV4([192, 168, 1, 2]))
        #expect(RemoteNetworkAddresses.isTailscaleV6([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        #expect(!RemoteNetworkAddresses.isTailscaleV6([0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        #expect(RemoteNetworkAddresses.bindable().first == "127.0.0.1")
        #expect(!RemoteNetworkAddresses.bindable().contains("0.0.0.0"))
    }

    @Test("websocket frames: masked round trip and fragmentation of big payloads")
    func frames() {
        let payload = Data((0..<200_000).map { UInt8($0 & 0xFF) })
        let framed = RemoteWebSocket.frames(opcode: .binary, payload: payload)
        // Three 64 KiB frames with 10 byte headers, then the rest with a 4 byte header.
        #expect(framed.count == payload.count + 3 * 10 + 4)
        #expect(framed[10 + 65536] == 0x00)
        #expect(framed[0] == 0x02)
        #expect(RemoteWebSocketHandshake.accept(key: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}
