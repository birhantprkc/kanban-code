import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Vault routes", .serialized)
struct VaultRoutesTests {
    private func fixture() async throws -> (RemoteServerFixture, VaultService) {
        let home = NSTemporaryDirectory() + "vault-routes-\(UUID().uuidString.prefix(8))"
        let vault = VaultService(
            kanbanHome: home, keys: MemoryVaultKeyProvider(), machine: "test", approvals: nil,
            cardTitle: { _ in nil }, cardSessions: { [:] }, peers: nil
        )
        try await vault.store.upsert(VaultSecret(name: "OPEN", value: "open-value", tier: .open))
        return (try await RemoteServerFixture(vault: vault), vault)
    }

    @Test func loopbackCallersNeedNoTokenButOutsideACardAreNotServed() async throws {
        let (f, _) = try await fixture()
        defer { f.shutdown() }
        let body = try JSONEncoder().encode(VaultReleaseRequest(mode: "run", names: ["OPEN"], cardId: "card_fake"))
        let (status, data) = try await f.request("POST", "/v1/vault/release", body: body)
        #expect(status == 403)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("human approval"))
        #expect(!text.contains("open-value"))
        // Other routes still want a token.
        #expect(try await f.request("GET", "/v1/board").0 == 401)
    }

    @Test func listingsNeverCarryValues() async throws {
        let (f, _) = try await fixture()
        defer { f.shutdown() }
        let (status, data) = try await f.request("GET", "/v1/vault/secrets")
        #expect(status == 200)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"OPEN\"") && !text.contains("open-value"))
    }

    @Test func theReplicaIsForFullScopePeers() async throws {
        let (f, vault) = try await fixture()
        defer { f.shutdown() }
        #expect(try await f.request("GET", "/v1/vault/replica").0 == 403)
        #expect(try await f.request("GET", "/v1/vault/replica", token: f.agentToken).0 == 403)
        let (status, data) = try await f.request("GET", "/v1/vault/replica", token: f.fullToken)
        #expect(status == 200)
        let body = try JSONDecoder().decode(VaultReplicaBody.self, from: data)
        #expect(body.blob.flatMap { Data(base64Encoded: $0) } == (await vault.store.encryptedBlob()))
    }

    @Test func vaultHookInstallsOnce() throws {
        let dir = NSTemporaryDirectory() + "vault-hook-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let settings = dir + "/settings.json"
        try #"{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"x"}]}]},"model":"m"}"#
            .write(toFile: settings, atomically: true, encoding: .utf8)
        #expect(try VaultHook.install(settingsPath: settings, scriptPath: dir + "/.kanban-code/vault-hook.sh"))
        #expect(try !VaultHook.install(settingsPath: settings, scriptPath: dir + "/.kanban-code/vault-hook.sh"))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settings))) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        #expect((hooks["PreToolUse"] as! [[String: Any]]).count == 1)
        #expect(hooks["Stop"] != nil && root["model"] as? String == "m")
    }
}
