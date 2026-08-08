import AppKit
import Testing

@testable import KanbanCode

@MainActor
@Suite("Chat selection coordinator")
struct ChatSelectionCoordinatorTests {

    private static let appearance = ChatTextAppearance(
        font: .systemFont(ofSize: 13), foregroundColor: .labelColor
    )

    private static let width: CGFloat = 690

    /// Stacks the views top to bottom in a real window, which is where the
    /// coordinator reads document order from.
    private static func stack(_ contents: [ChatTextContent]) -> (
        NSWindow, [SelectableMarkdownText.WrappingTextView]
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 2_000),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container

        var top = container.bounds.maxY
        var views: [SelectableMarkdownText.WrappingTextView] = []
        for content in contents {
            let view = SelectableMarkdownText.WrappingTextView.make()
            view.configure(content: content, appearance: self.appearance, highlight: nil)
            let size = view.fittingSize(forWidth: self.width)
            top -= size.height
            // Window coordinates grow upwards, so the first view gets the
            // highest origin.
            view.frame = NSRect(x: 0, y: top, width: self.width, height: size.height)
            top -= 12
            container.addSubview(view)
            views.append(view)
        }
        return (window, views)
    }

    /// A point just below a view, which is where a downward drag ends up.
    private static func belowBottom(of view: NSView) -> NSPoint {
        let frame = view.convert(view.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.minY - 4)
    }

    @Test("a drag started in one message extends into the next")
    func dragCrossesMessages() {
        let coordinator = ChatSelectionCoordinator()
        let (window, views) = Self.stack([.plain("First message"), .plain("Second message")])
        _ = window
        views.forEach { coordinator.register($0) }

        coordinator.beginDrag(in: views[0], at: 0)
        coordinator.extendDrag(toWindowPoint: Self.belowBottom(of: views[1]))
        coordinator.endDrag()

        #expect(coordinator.selectedText() == "First message\n\nSecond message")
        // The anchor keeps a real selection so its caret behaves normally.
        #expect(views[0].selectedRange().length == 13)
        // The one it reached into is painted instead, or it would draw grey.
        #expect(views[1].selectedRange().length == 0)
        #expect(views[1].carriedSelectionRange?.length == 14)
    }

    @Test("dragging upwards selects from the anchor back to the drag point")
    func dragUpwards() {
        let coordinator = ChatSelectionCoordinator()
        let (window, views) = Self.stack([.plain("First message"), .plain("Second message")])
        _ = window
        views.forEach { coordinator.register($0) }

        let length = views[1].textStorage?.length ?? 0
        coordinator.beginDrag(in: views[1], at: length)
        let top = views[0].convert(views[0].bounds, to: nil)
        coordinator.extendDrag(toWindowPoint: NSPoint(x: top.midX, y: top.maxY + 4))
        coordinator.endDrag()

        #expect(coordinator.selectedText() == "First message\n\nSecond message")
    }

    @Test("a selection inside one message is left to AppKit")
    func singleMessageStaysNative() {
        let coordinator = ChatSelectionCoordinator()
        let (window, views) = Self.stack([.plain("First message"), .plain("Second message")])
        _ = window
        views.forEach { coordinator.register($0) }

        coordinator.beginDrag(in: views[0], at: 0)
        let frame = views[0].convert(views[0].bounds, to: nil)
        coordinator.extendDrag(toWindowPoint: NSPoint(x: frame.midX, y: frame.midY))
        coordinator.endDrag()

        #expect(coordinator.selectedText() == nil)
        #expect(views[0].selectedRange().length > 0)
    }

    @Test("a new drag drops the previous selection")
    func newDragClearsTheOldOne() {
        let coordinator = ChatSelectionCoordinator()
        let (window, views) = Self.stack([.plain("First message"), .plain("Second message")])
        _ = window
        views.forEach { coordinator.register($0) }

        coordinator.beginDrag(in: views[0], at: 0)
        coordinator.extendDrag(toWindowPoint: Self.belowBottom(of: views[1]))
        coordinator.endDrag()
        coordinator.beginDrag(in: views[1], at: 0)

        #expect(views[0].selectedRange().length == 0)
        #expect(views[1].carriedSelectionRange == nil)
        #expect(coordinator.selectedText() == nil)
    }

    @Test("select all covers every message in order")
    func selectAllCoversEverything() {
        let coordinator = ChatSelectionCoordinator()
        let (window, views) = Self.stack([.plain("one"), .plain("two"), .plain("three")])
        _ = window
        views.forEach { coordinator.register($0) }

        coordinator.selectAll()

        #expect(coordinator.selectedText() == "one\n\ntwo\n\nthree")
    }

    /// Views arrive in whatever order SwiftUI mounts them, which is not the
    /// order they are drawn in, so the copy order comes from the layout.
    @Test("copy follows document order, not registration order")
    func copyFollowsDocumentOrder() {
        let coordinator = ChatSelectionCoordinator()
        let (window, views) = Self.stack([.plain("one"), .plain("two"), .plain("three")])
        _ = window
        for view in views.reversed() { coordinator.register(view) }

        coordinator.selectAll()

        #expect(coordinator.selectedText() == "one\n\ntwo\n\nthree")
    }

    @Test("a message that scrolled away drops out of the run")
    func unregisteredViewsAreSkipped() {
        let coordinator = ChatSelectionCoordinator()
        let (window, views) = Self.stack([.plain("one"), .plain("two"), .plain("three")])
        _ = window
        views.forEach { coordinator.register($0) }
        coordinator.unregister(views[1])

        coordinator.selectAll()

        #expect(coordinator.selectedText() == "one\n\nthree")
    }

    // MARK: - Flattening

    @Test("a table copies as tab separated rows")
    func tableCopiesAsRows() {
        let markdown = """
            | Component | Version |
            | --- | --- |
            | alpha | 1.2.0 |
            | beta | 3.4.5 |
            """
        let coordinator = ChatSelectionCoordinator()
        let (window, views) = Self.stack([.plain("before"), .markdown(markdown)])
        _ = window
        views.forEach { coordinator.register($0) }

        coordinator.selectAll()

        let copied = coordinator.selectedText()
        #expect(
            copied == """
                before

                Component\tVersion
                alpha\t1.2.0
                beta\t3.4.5
                """
        )
    }

    /// A fenced block is one paragraph held together by line separators, so
    /// pasting it raw would give one long line.
    @Test("a code block copies with its line breaks back")
    func codeBlockKeepsItsLines() {
        let markdown = """
            ```swift
            let a = 1
            let b = 2
            ```
            """
        let coordinator = ChatSelectionCoordinator()
        let (window, views) = Self.stack([.plain("before"), .markdown(markdown)])
        _ = window
        views.forEach { coordinator.register($0) }

        coordinator.selectAll()

        #expect(coordinator.selectedText() == "before\n\nlet a = 1\nlet b = 2")
    }
}
