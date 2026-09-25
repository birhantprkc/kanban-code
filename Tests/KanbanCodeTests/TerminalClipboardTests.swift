import Testing
import Foundation
import SwiftTerm

private final class ClipboardRecorder: TerminalDelegate {
    var copied: [String] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func clipboardCopy(source: Terminal, content: Data) {
        copied.append(String(decoding: content, as: UTF8.self))
    }
}

@Suite("Terminal clipboard")
struct TerminalClipboardTests {
    /// agtop draws its own selection and copies it with OSC 52 when a drag
    /// ends, the way bubbletea's SetClipboard writes it.
    @Test("OSC 52 from the program reaches the clipboard")
    func osc52Copies() {
        let recorder = ClipboardRecorder()
        let terminal = Terminal(delegate: recorder, options: TerminalOptions(cols: 20, rows: 5))
        let payload = Data("selected text".utf8).base64EncodedString()
        terminal.feed(text: "\u{1b}]52;c;\(payload)\u{07}")
        #expect(recorder.copied == ["selected text"])
    }
}
