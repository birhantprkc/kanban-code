import AppKit
import SwiftUI

/// Extends a text selection across the separate text views a transcript is
/// made of.
///
/// One message is one text view, which is one selection domain, so AppKit will
/// never carry a drag from one into the next on its own. This tracks the drag
/// itself: the view where it started keeps its native selection, the views it
/// passes over are painted with temporary attributes, and copy stitches them
/// back together in document order.
@MainActor
final class ChatSelectionCoordinator {

    private struct Registration {
        weak var view: SelectableMarkdownText.WrappingTextView?
    }

    private var registrations: [Registration] = []
    private weak var anchorView: SelectableMarkdownText.WrappingTextView?
    private var anchorIndex = 0
    /// The selected range per view, including the anchor's.
    private var ranges: [ObjectIdentifier: NSRange] = [:]

    // MARK: - Registration

    func register(_ view: SelectableMarkdownText.WrappingTextView) {
        self.registrations.removeAll { $0.view == nil || $0.view === view }
        self.registrations.append(Registration(view: view))
    }

    func unregister(_ view: SelectableMarkdownText.WrappingTextView) {
        self.registrations.removeAll { $0.view == nil || $0.view === view }
        self.ranges[ObjectIdentifier(view)] = nil
    }

    /// Live views in document order, top to bottom.
    ///
    /// Read from the layout rather than from a registration order, so a view
    /// that scrolls in or out cannot leave the sequence stale.
    private var orderedViews: [SelectableMarkdownText.WrappingTextView] {
        self.registrations
            .compactMap(\.view)
            .filter { $0.window != nil }
            .map { ($0, $0.convert($0.bounds, to: nil).maxY) }
            // Window coordinates grow upwards, so the topmost view has the
            // largest y.
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: - Dragging

    func beginDrag(in view: SelectableMarkdownText.WrappingTextView, at index: Int) {
        self.clearAll()
        self.anchorView = view
        self.anchorIndex = index
        self.ranges[ObjectIdentifier(view)] = NSRange(location: index, length: 0)
    }

    func extendDrag(toWindowPoint point: NSPoint) {
        guard let anchorView else { return }
        let views = self.orderedViews
        guard
            let anchor = views.firstIndex(of: anchorView),
            let target = self.viewIndex(at: point, in: views)
        else { return }

        let targetView = views[target]
        let local = targetView.convert(point, from: nil)
        let targetIndex = self.characterIndex(in: targetView, at: local)

        var updated: [ObjectIdentifier: NSRange] = [:]
        if target == anchor {
            let lower = min(self.anchorIndex, targetIndex)
            let upper = max(self.anchorIndex, targetIndex)
            updated[ObjectIdentifier(anchorView)] = NSRange(
                location: lower, length: upper - lower)
        } else {
            let downwards = target > anchor
            let first = min(anchor, target)
            let last = max(anchor, target)
            for position in first...last {
                let view = views[position]
                let length = view.textStorage?.length ?? 0
                let range: NSRange
                if view === anchorView {
                    range =
                        downwards
                        ? NSRange(location: self.anchorIndex, length: length - self.anchorIndex)
                        : NSRange(location: 0, length: self.anchorIndex)
                } else if view === targetView {
                    range =
                        downwards
                        ? NSRange(location: 0, length: targetIndex)
                        : NSRange(location: targetIndex, length: length - targetIndex)
                } else {
                    range = NSRange(location: 0, length: length)
                }
                updated[ObjectIdentifier(view)] = range
            }
        }
        self.apply(updated, views: views)
    }

    func endDrag() {}

    /// The view under the point, or the nearest one when the pointer is over
    /// something that is not part of the run, like a collapsed card.
    private func viewIndex(
        at point: NSPoint, in views: [SelectableMarkdownText.WrappingTextView]
    ) -> Int? {
        guard !views.isEmpty else { return nil }
        for (index, view) in views.enumerated() {
            let frame = view.convert(view.bounds, to: nil)
            if point.y <= frame.maxY, point.y >= frame.minY { return index }
        }
        // Above the first or below the last, in document order.
        let firstFrame = views[0].convert(views[0].bounds, to: nil)
        if point.y > firstFrame.maxY { return 0 }
        return views.count - 1
    }

    private func characterIndex(
        in view: SelectableMarkdownText.WrappingTextView, at point: NSPoint
    ) -> Int {
        let length = view.textStorage?.length ?? 0
        if point.y < 0 { return 0 }
        if point.y > view.bounds.height { return length }
        return min(view.characterIndexForInsertion(at: point), length)
    }

    // MARK: - Painting

    private func apply(
        _ updated: [ObjectIdentifier: NSRange],
        views: [SelectableMarkdownText.WrappingTextView]
    ) {
        for view in views {
            let key = ObjectIdentifier(view)
            let range = updated[key] ?? NSRange(location: 0, length: 0)
            self.ranges[key] = range.length > 0 ? range : nil

            if view === self.anchorView {
                // The view the drag started in keeps a real selection, so the
                // caret and its own copy behave normally.
                view.setSelectedRange(range)
                view.clearCarriedSelection()
            } else {
                view.setSelectedRange(NSRange(location: 0, length: 0))
                // A selection AppKit did not make is drawn unemphasised, which
                // reads as a different colour from the anchor. Paint it instead.
                view.carrySelection(range)
            }
        }
    }

    func clearAll() {
        for view in self.registrations.compactMap(\.view) {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.clearCarriedSelection()
        }
        self.ranges.removeAll()
        self.anchorView = nil
    }

    // MARK: - Commands

    func selectAll() {
        let views = self.orderedViews
        guard let first = views.first else { return }
        self.anchorView = first
        self.anchorIndex = 0
        var updated: [ObjectIdentifier: NSRange] = [:]
        for view in views {
            updated[ObjectIdentifier(view)] = NSRange(
                location: 0, length: view.textStorage?.length ?? 0)
        }
        self.apply(updated, views: views)
    }

    /// The selected text in document order.
    ///
    /// Returns nil when only one view is involved, so AppKit's own copy handles
    /// the ordinary case.
    func selectedText() -> String? {
        let views = self.orderedViews.filter { (self.ranges[ObjectIdentifier($0)]?.length ?? 0) > 0 }
        guard views.count > 1 else { return nil }
        return
            views
            .compactMap { view -> String? in
                guard let range = self.ranges[ObjectIdentifier(view)],
                    let storage = view.textStorage
                else { return nil }
                return ChatSelectionText.plainText(storage, range: range)
            }
            .joined(separator: "\n\n")
    }
}

// MARK: - Plain text conversion

enum ChatSelectionText {
    /// Flattens a range of rendered markdown back to text worth pasting.
    ///
    /// Two things need undoing: a code block is one paragraph held together by
    /// line separators, and a table cell is a paragraph of its own, so copying
    /// one raw would give a table one cell per line instead of rows.
    static func plainText(_ attributed: NSAttributedString, range: NSRange) -> String {
        let string = attributed.string as NSString
        var out = ""
        var index = range.location

        while index < NSMaxRange(range) {
            let paragraph = string.paragraphRange(for: NSRange(location: index, length: 0))
            let clipped = NSIntersectionRange(paragraph, range)
            guard clipped.length > 0 else { break }

            var text = string.substring(with: clipped)
                .replacingOccurrences(of: "\u{2028}", with: "\n")
            let hadNewline = text.hasSuffix("\n")
            if hadNewline { text.removeLast() }

            if let cell = self.tableCell(in: attributed, at: clipped.location) {
                let isLastColumn =
                    cell.startingColumn + cell.columnSpan >= cell.table.numberOfColumns
                out += text + (isLastColumn ? "\n" : "\t")
            } else {
                out += text + (hadNewline ? "\n" : "")
            }
            index = NSMaxRange(paragraph)
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    private static func tableCell(
        in attributed: NSAttributedString, at location: Int
    ) -> NSTextTableBlock? {
        guard location < attributed.length,
            let style = attributed.attribute(.paragraphStyle, at: location, effectiveRange: nil)
                as? NSParagraphStyle
        else { return nil }
        return style.textBlocks.compactMap { $0 as? NSTextTableBlock }.last
    }
}

// MARK: - Environment

private struct ChatSelectionCoordinatorKey: EnvironmentKey {
    static let defaultValue: ChatSelectionCoordinator? = nil
}

extension EnvironmentValues {
    var chatSelectionCoordinator: ChatSelectionCoordinator? {
        get { self[ChatSelectionCoordinatorKey.self] }
        set { self[ChatSelectionCoordinatorKey.self] = newValue }
    }
}
