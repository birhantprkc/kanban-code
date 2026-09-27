import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

@Suite("Prompt Image Layout")
struct PromptImageLayoutTests {
    @Test("parts split text around image markers")
    func partsSplitTextAroundMarkers() {
        let parts = PromptImageLayout.parts(
            in: "before [Image #1] middle [Image #2] after",
            imageCount: 2
        )
        #expect(parts == [
            .init(text: "before "),
            .init(text: "", imageIndex: 0),
            .init(text: " middle "),
            .init(text: "", imageIndex: 1),
            .init(text: " after"),
        ])
    }

    @Test("invalid markers stay as text")
    func invalidMarkersStayText() {
        let parts = PromptImageLayout.parts(in: "a [Image #3] b", imageCount: 1)
        #expect(parts == [.init(text: "a [Image #3] b")])
    }

    @Test("markdown replacement keeps image position")
    func markdownReplacementKeepsPosition() {
        let text = PromptImageLayout.replacingMarkersWithMarkdown(
            in: "a [Image #1] b",
            imagePaths: ["/tmp/x.png"]
        )
        #expect(text == "a ![](/tmp/x.png) b")
    }

    @Test("markdown replacement appends legacy images when no marker exists")
    func markdownReplacementAppendsLegacyImages() {
        let text = PromptImageLayout.replacingMarkersWithMarkdown(
            in: "a",
            imagePaths: ["/tmp/x.png"]
        )
        #expect(text == "a\n![](/tmp/x.png)")
    }

    @Test("arranged numbers markers in text order and drops unnamed images")
    func arranged() {
        let out = PromptImageLayout.arranged(text: "a [Image #2] b [Image #2] c [Image #3]", images: ["x", "y", "z"])
        #expect(out.text == "a [Image #1] b [Image #1] c [Image #2]")
        #expect(out.images == ["y", "z"])
        let legacy = PromptImageLayout.arranged(text: "plain", images: ["x"])
        #expect(legacy.text == "plain")
        #expect(legacy.images == ["x"])
    }

    @Test("removing markers and reading markdown images back as markers")
    func markerHelpers() {
        #expect(PromptImageLayout.removingMarkers(from: "see [Image #1] here", imageCount: 1) == "see here")
        #expect(PromptImageLayout.marksEveryImage("a [Image #1] [Image #2]", imageCount: 2))
        #expect(!PromptImageLayout.marksEveryImage("a [Image #1]", imageCount: 2))
        #expect(PromptImageLayout.replacingMarkdownImagesWithMarkers(in: "[Image #1] and ![](/tmp/a.png), ![x](/tmp/b.JPG)")
                == "[Image #1] and [Image #2], [Image #3]")
        #expect(PromptImageLayout.replacingMarkdownImagesWithMarkers(in: "![link](https://x.y/a.png)") == "![link](https://x.y/a.png)")
    }

    @Test("a broken marker does not hide the next one")
    func brokenMarker() {
        let parts = PromptImageLayout.parts(in: "a [Image #1 b [Image #2] c", imageCount: 2)
        #expect(parts == [.init(text: "a [Image #1 b "), .init(text: "", imageIndex: 1), .init(text: " c")])
    }
}
