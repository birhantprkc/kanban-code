import Foundation
import Testing

@testable import SwiftTerm

@Suite("Terminal link resolver")
struct TerminalLinkResolverTests {
    @Test("absolute paths use file URL semantics")
    func absolutePath() {
        let path = "/Users/example/My Project/image.png"
        let url = TerminalLinkResolver.url(for: path)

        #expect(url?.isFileURL == true)
        #expect(url?.path == path)
    }

    @Test("tilde paths expand to file URLs")
    func tildePath() {
        let url = TerminalLinkResolver.url(for: "~/Desktop/image.png")

        #expect(url?.isFileURL == true)
        #expect(url?.path == NSHomeDirectory() + "/Desktop/image.png")
    }

    @Test("web links retain URL semantics")
    func webURL() {
        let url = TerminalLinkResolver.url(for: "https://example.com/image.png")

        #expect(url?.isFileURL == false)
        #expect(url?.absoluteString == "https://example.com/image.png")
    }
}
