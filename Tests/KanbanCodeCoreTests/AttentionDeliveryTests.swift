import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Attention delivery: cardless requests, one phone message, plain copy")
struct AttentionDeliveryTests {
    final class Recorder: MacAttentionNotifier, PhonePushSender, @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        let silentCopy: Bool
        init(silentCopy: Bool = true) { self.silentCopy = silentCopy }
        var sendsSilentCopy: Bool { silentCopy }
        func record(_ e: String) { lock.withLock { events.append(e) } }
        func post(_ request: AttentionRequest, cardName: String?) async { record("mac+\(request.id)") }
        func remove(id: String) async { record("mac-\(id)") }
        func send(_ request: AttentionRequest, cardName: String?, level: PhonePushLevel) async throws { record("phone:\(level.rawValue):\(request.id)") }
        func withdraw(_ request: AttentionRequest) async {}
    }

    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(_ s: TimeInterval) { lock.withLock { value += s } }
    }

    let t0 = Date(timeIntervalSince1970: 3_000_000)

    func vaultRequest(card: String?) -> AttentionRequest {
        AttentionRequest(
            id: "vault_1", cardId: card, kind: .vaultApproval,
            title: "A process outside any card wants to change the tier of the Stripe API key",
            body: "Live Stripe keys move money, so every use should ask first.",
            options: AttentionRequest.vaultApprovalOptions, createdAt: t0, requiresBiometry: true,
            machineId: "mac-id")
    }

    @Test("a vault request with no card reaches the Mac at once and the phone after the delay, with Kanban in front", arguments: [nil, "card_1"] as [String?])
    func vaultReachesMacAndPhone(card: String?) async {
        let clock = Clock(t0)
        let mac = Recorder()
        let phone = Recorder(silentCopy: false)
        let center = AttentionCenter(
            mac: mac, phone: phone,
            localPresence: {
                MacPresence(isKanbanFrontmost: true, visibleCardId: "card_2", visibleTab: "terminal", idleSeconds: 1, reportedAt: clock.now)
            },
            localMachineId: { "mac-id" }, now: { clock.now })
        await center.deliver(vaultRequest(card: card))
        #expect(mac.events == ["mac+vault_1"])
        #expect(phone.events.isEmpty)
        clock.advance(181)
        await center.evaluateAll()
        #expect(phone.events == ["phone:timeSensitive:vault_1"])
        clock.advance(60)
        await center.evaluateAll()
        #expect(phone.events.count == 1)
    }

    @Test("Pushover takes one message per request: no silent copy, only the alert")
    func pushoverHasNoSilentCopy() {
        #expect(PushoverAttentionSender(token: "t", userKey: "u").sendsSilentCopy == false)
        var settings = AttentionPolicySettings()
        settings.phoneSilentCopy = false
        let request = vaultRequest(card: nil)
        let present = MacPresence(idleSeconds: 1, reportedAt: t0)
        #expect(AttentionPolicy.steps(for: request, delivered: .init(), presence: present, now: t0, settings: settings) == [.postMac])
        let away = MacPresence(idleSeconds: 1, screenLocked: true, reportedAt: t0)
        #expect(AttentionPolicy.steps(for: request, delivered: .init(), presence: away, now: t0, settings: settings) == [.postMac, .phoneAlert])
    }

    @Test("the log says why a request was or was not delivered")
    func explains() {
        let request = vaultRequest(card: nil)
        let present = MacPresence(idleSeconds: 1, reportedAt: t0)
        let why = AttentionPolicy.explain(request, presence: present, now: t0, settings: .init(), macAvailable: true)
        #expect(why.contains("Mac in use") && why.contains("Mac on") && why.contains("phone on"))
        var looking = vaultRequest(card: "card_1")
        looking.kind = .question
        let watching = MacPresence(isKanbanFrontmost: true, visibleCardId: "card_1", visibleTab: "chat", idleSeconds: 1, reportedAt: t0)
        #expect(AttentionPolicy.explain(looking, presence: watching, now: t0, settings: .init(), macAvailable: true).contains("looking at card card_1"))
        #expect(AttentionPolicy.explain(request, presence: nil, now: t0, settings: .init(), macAvailable: false).contains("no Mac notifier"))
    }

    @Test("a card named after its whole first prompt makes a short title")
    func shortCardNames() {
        let long = "Use the AskUserQuestion tool to ask me exactly one question about lunch and wait"
        let short = AttentionCopy.shortName(long)
        #expect(short == "Use the AskUserQuestion tool to ask me...")
        #expect(short.count <= AttentionCopy.cardNameLimit + 3)
        #expect(AttentionCopy.shortName("Weekly newsletter") == "Weekly newsletter")
        let q = AttentionRequest(id: "q", cardId: "c", kind: .question, title: "Question", body: "Tea?")
        #expect(AttentionCopy.notification(for: q, cardName: long).title == "Use the AskUserQuestion tool to ask me... is asking you a question")
    }

    @Test("a permission notification is one plain line; the command stays in the detail sheet")
    func permissionCopy() {
        let use = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cd /root/x && ffmpeg -i a.mov a.mp4","description":"Convert the recording to mp4"}}]}}"#
        let call = AttentionDetector.pendingToolCall(inLines: [use])
        #expect(call?.summary == "Claude wants to run a command: Convert the recording to mp4")
        let body = MasterEngine.permissionBody(message: "Claude needs your permission to use Bash", tool: call)
        #expect(body == "Claude wants to run a command: Convert the recording to mp4\n\nBash: cd /root/x && ffmpeg -i a.mov a.mp4")
        let request = AttentionRequest(id: "perm_1", cardId: "c", kind: .permission, title: "Permission needed", body: body)
        let copy = AttentionCopy.notification(for: request, cardName: "Video card")
        #expect(copy == ("Video card needs your permission", "Claude wants to run a command: Convert the recording to mp4"))
        let push = Dictionary(PushoverAttentionSender.fields(for: request, cardName: "Video card", level: .timeSensitive), uniquingKeysWith: { a, _ in a })
        #expect(push["message"]?.contains("ffmpeg") == false)

        let rush = MasterEngine.permissionBody(message: "Bash cd /root/x && ffmpeg -i a.mov a.mp4", tool: nil)
        #expect(AttentionCopy.firstParagraph(rush) == "Claude wants to run a Bash command")
        #expect(rush.hasSuffix("Bash: cd /root/x && ffmpeg -i a.mov a.mp4"))
        #expect(MasterEngine.permissionBody(message: "Claude needs your permission to use Bash", tool: nil) == "Claude needs your permission to use Bash")
        #expect(MasterEngine.permissionBody(message: nil, tool: nil) == "Waiting for your permission")
        #expect(AttentionDetector.ToolCall(name: "Edit", detail: "/a/b/notes.md").summary == "Claude wants to edit notes.md")
    }

    @Test("an edit of many secrets names the change before the secrets")
    func manySecretEdit() {
        let details = VaultApprovalDetails(
            action: .edit, origin: .outside,
            secrets: [.init(name: "STRIPE_API_KEY", label: "Stripe API key", tier: "Always ask"), .init(name: "STRIPE_SECRET", label: "Stripe secret", tier: "Always ask")],
            changes: ["tier", "lease time"])
        #expect(AttentionCopy.vaultHeadline(details)
            == "A process outside any card wants to change the tier and lease time of the Stripe API key and the Stripe secret")
    }

    @Test("test runs log to their own file")
    func testRunsLogApart() {
        #expect(KanbanCodeLog.isTestRun)
    }
}
