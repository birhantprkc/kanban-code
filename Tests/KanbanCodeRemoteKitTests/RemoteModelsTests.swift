import Testing
import Foundation
@testable import KanbanCodeRemoteKit

@Suite("remote wire types")
struct RemoteModelsTests {
    @Test("Dates travel as ISO 8601 with milliseconds and come back the same")
    func dates() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000.5)
        let card = RemoteCard(id: "card_1", title: "Fix it", column: .waiting, runtime: .agtop, updatedAt: at)
        let data = try JSONEncoder.remote.encode(card)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""updatedAt":"2026-09-21T"#))
        #expect(json.contains(#".500Z""#))
        #expect(json.contains(#""column":"requires_attention""#))
        let back = try JSONDecoder.remote.decode(RemoteCard.self, from: data)
        #expect(abs(back.updatedAt.timeIntervalSince(at)) < 0.001)
    }

    @Test("Dates without fractions from other clients still parse")
    func plainDates() throws {
        let json = #"{"text":"hi","mode":"now"}"#
        let req = try JSONDecoder.remote.decode(RemotePromptRequest.self, from: Data(json.utf8))
        #expect(req.mode == .now)
        #expect(RemoteDates.parse("2026-09-26T10:00:00Z") != nil)
    }
}
