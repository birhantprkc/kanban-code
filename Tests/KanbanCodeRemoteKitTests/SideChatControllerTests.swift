import Foundation
import Synchronization
import Testing

@testable import KanbanCodeRemoteKit

/// A transport whose runs answer a bit more on every read.
private final class FakeSideChat: Sendable {
    struct State {
        var requests: [RemoteSideChatRequest] = []
        var polls = 0
        var cancelled: [String] = []
        var failStart: String?
        /// The answer after each read; the last one ends the run.
        var steps: [String] = ["Half", "Half done."]
    }

    let state = Mutex(State())

    var transport: SideChatController.Transport {
        SideChatController.Transport(
            start: { [self] request in
                try state.withLock { s in
                    if let message = s.failStart { throw RemoteError(message) }
                    s.requests.append(request)
                    s.polls = 0
                    return RemoteSideChatRun(id: "run\(s.requests.count)", cardId: "card_1", kind: request.kind,
                                             since: request.kind == .catchup ? RemoteSideChatSince(text: "do it", offset: 40) : nil,
                                             refs: request.kind == .catchup ? [RemoteSideChatRef(ref: "m1", offset: 40, role: "you", preview: "do it")] : nil)
                }
            },
            poll: { [self] runId in
                state.withLock { s in
                    let step = min(s.polls, s.steps.count - 1)
                    s.polls += 1
                    return RemoteSideChatRun(id: runId, cardId: "card_1", kind: .btw,
                                             state: step == s.steps.count - 1 ? .done : .running, text: s.steps[step])
                }
            },
            cancel: { [self] runId in state.withLock { $0.cancelled.append(runId) } })
    }
}

@MainActor
private func settle(_ controller: SideChatController, until done: @MainActor () -> Bool) async {
    for _ in 0..<400 where !done() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("Side chat controller")
@MainActor
struct SideChatControllerTests {
    private func controller(_ fake: FakeSideChat) -> SideChatController {
        let controller = SideChatController(transport: fake.transport)
        controller.pollInterval = .milliseconds(5)
        return controller
    }

    @Test("a question opens the panel, streams and ends with the whole answer")
    func ask() async {
        let fake = FakeSideChat()
        let chat = controller(fake)
        chat.run(.btw("what is left?"))
        #expect(chat.state.isOpen)
        #expect(chat.state.isRunning)
        #expect(chat.state.entries.first?.question == "what is left?")

        await settle(chat) { !chat.state.isRunning }
        #expect(chat.state.entries.count == 1)
        #expect(chat.state.entries.first?.answer == "Half done.")
        #expect(chat.state.entries.first?.id == "run1")
        #expect(fake.state.withLock { $0.requests.first?.history } == nil)
    }

    @Test("a follow-up carries the earlier exchanges")
    func followUp() async {
        let fake = FakeSideChat()
        let chat = controller(fake)
        chat.ask(.btw, question: "what is left?")
        await settle(chat) { !chat.state.isRunning }
        chat.ask(.btw, question: "and after that?")
        await settle(chat) { !chat.state.isRunning }

        #expect(chat.state.entries.map(\.question) == ["what is left?", "and after that?"])
        let second = fake.state.withLock { $0.requests.last }
        #expect(second?.question == "and after that?")
        #expect(second?.history == [RemoteSideChatExchange(question: "what is left?", answer: "Half done.")])
    }

    @Test("a catch-up keeps where it starts and the messages it can cite")
    func catchUp() async {
        let fake = FakeSideChat()
        fake.state.withLock { $0.steps = [#"{"section":"status","text":"Done.","refs":["m1"]}"#] }
        let chat = controller(fake)
        chat.run(.catchup)
        await settle(chat) { !chat.state.isRunning }

        let entry = chat.state.entries.first
        #expect(entry?.question == SideChatState.catchUpQuestion)
        #expect(entry?.since?.offset == 40)
        #expect(entry?.refs.map(\.ref) == ["m1"])
        #expect(entry?.catchUp?.sections.first?.items.first?.text == "Done.")
        #expect(fake.state.withLock { $0.requests.first?.question } == nil)
    }

    @Test("one question at a time, and an empty one is not asked")
    func oneAtATime() async {
        let fake = FakeSideChat()
        let chat = controller(fake)
        chat.ask(.btw, question: "   ")
        #expect(chat.state.entries.isEmpty)
        chat.ask(.btw, question: "first")
        chat.ask(.btw, question: "second")
        await settle(chat) { !chat.state.isRunning }
        #expect(chat.state.entries.map(\.question) == ["first"])
    }

    @Test("/btw alone opens the panel with nothing asked")
    func openEmpty() {
        let fake = FakeSideChat()
        let chat = controller(fake)
        chat.run(.btw(""))
        #expect(chat.state.isOpen)
        #expect(chat.state.entries.isEmpty)
        #expect(fake.state.withLock { $0.requests.isEmpty })
    }

    @Test("a run that cannot start shows its reason")
    func failure() async {
        let fake = FakeSideChat()
        fake.state.withLock { $0.failStart = "the session has no transcript yet" }
        let chat = controller(fake)
        chat.ask(.btw, question: "anything?")
        await settle(chat) { !chat.state.isRunning }
        #expect(chat.state.entries.first?.error == "the session has no transcript yet")
        #expect(chat.state.isOpen)
    }

    @Test("dismissing closes the panel and stops the run")
    func dismiss() async {
        let fake = FakeSideChat()
        fake.state.withLock { $0.steps = Array(repeating: "…", count: 10_000) + ["end"] }
        let chat = controller(fake)
        chat.ask(.btw, question: "long one")
        await settle(chat) { chat.state.runningId == "run1" }
        chat.dismiss()
        #expect(!chat.state.isOpen)
        #expect(chat.state.entries.isEmpty)
        await settle(chat) { fake.state.withLock { $0.cancelled } == ["run1"] }
        #expect(fake.state.withLock { $0.cancelled } == ["run1"])
    }

    @Test("the hand-off to the main chat is the reply, then the side chat as context")
    func handoff() async {
        let fake = FakeSideChat()
        let chat = controller(fake)
        chat.ask(.btw, question: "what is left?")
        await settle(chat) { !chat.state.isRunning }
        let prompt = chat.mainChatPrompt(reply: "Finish it then")
        #expect(prompt.hasPrefix("Finish it then\n\n---\n"))
        #expect(prompt.contains("I asked: what is left?"))
        #expect(prompt.contains("Half done."))
    }

    @Test("a citation link names its message by time and round-trips its id")
    func links() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let refs = [RemoteSideChatRef(ref: "m7", offset: 900, role: "assistant", at: at, preview: "done")]
        let item = CatchUpSummary.Item(id: 0, text: "All moved.", refs: ["m7", "m99"])
        let text = SideChatLinks.attributed(item, refs: refs, timeZone: TimeZone(identifier: "UTC")!)
        let links = text.runs.compactMap(\.link)
        // The citation the index does not hold is dropped.
        #expect(links.count == 1)
        #expect(SideChatLinks.ref(from: try #require(links.first)) == "m7")
        #expect(String(text.characters).hasPrefix("All moved. "))
        #expect(String(text.characters).hasSuffix("08:00"))
        #expect(SideChatLinks.ref(from: URL(string: "https://example.com/ref/m7")!) == nil)
    }
}
