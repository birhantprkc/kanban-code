# swift-markdown-ui (vendored fork)

Upstream: https://github.com/gonzalezreal/swift-markdown-ui
Forked at: v2.4.1 (`5f613358148239d0292c0cef674a3c2314737f9e`)
License: MIT, see `LICENSE` (unchanged, copyright the original authors)

## Why it is vendored

Chat messages need a drag selection that runs across a whole message and on
into the next one. Upstream renders every block as its own SwiftUI view inside
a `VStack` (`Views/Blocks/BlockSequence.swift`), and SwiftUI text selection
cannot span sibling views, so a selection stops at the first block boundary.

The fix is a second renderer that turns the same document into one
`NSAttributedString`, which one `NSTextView` can then select across in a single
run, tables included. It has to live in here because the pieces it needs are
`internal`: `BlockNode`, `InlineNode` and `[BlockNode](markdown:)` are all
invisible from the app, so the AST cannot be walked from outside.

Rendering must stay identical to the SwiftUI path: it is the look the app
already has. `Tests/KanbanCodeTests/MarkdownParityTests.swift` renders the same
fixtures both ways, compares them construct by construct, and writes a
side-by-side image to `.claude/tmp/markdown-parity/`.

## Local changes

Everything is additive and lives under `Sources/MarkdownUI/Renderer/AppKit/`,
marked with a `// kanban-code:` comment so a version bump can find it. No
upstream file is modified.

- `MarkdownAttributedStringRenderer.swift` — walks `[BlockNode]` and emits one
  attributed string. Tables become a real `NSTextTable` with a cell per column,
  blockquotes and code blocks single cell tables, thematic breaks an
  attachment. TextKit 1 only: `NSTextTable` is laid out by `NSLayoutManager`
  and by nothing in TextKit 2.
- `AppKitInlineRenderer.swift` — the inline sibling of
  `AttributedStringInlineRenderer`, emitting AppKit scope attributes
  (`.font: NSFont`, `.foregroundColor: NSColor`) rather than SwiftUI ones, which
  an `NSTextStorage` would drop. Styling still comes from the `Theme`, through
  the public `TextStyle._collectAttributes(in:)`.
- `MarkdownBlockMetrics.swift` — the block geometry as data. `BlockStyle` erases
  its body to `AnyView`, so margins, paddings, radii, bar widths and row
  backgrounds cannot be read back out of a `Theme` and have to be declared
  alongside it. The app's is `Sources/KanbanCode/ChatMarkdownMetrics.swift`,
  which mirrors `chatMarkdownTheme`.
- `MarkdownBlockDecoration.swift` — marks ranges that need a shape TextKit
  cannot draw itself: `NSTextBlock` corners are always square, so a rounded
  code block background or quote bar is painted by
  `Sources/KanbanCode/MarkdownLayoutManager.swift` instead.

The one edit to an upstream file is in `Parser/MarkdownParser.swift`, where the
two cmark imports lost their `@_implementationOnly`. That attribute only means
anything with library evolution turned on, which a local package does not use,
and the compiler warns that the combination is unstable.

## Known differences from the SwiftUI path

- Code blocks wrap instead of scrolling horizontally. Upstream's theme puts
  them in a `ScrollView(.horizontal)`, and a nested scroller cannot exist inside
  one text run.
- Images degrade to their alt text, linked to the source. The chat renders
  attachments separately anyway.

## Upgrading

1. Diff the new upstream tag against `5f61335`.
2. Nothing in `Sources/MarkdownUI/Renderer/AppKit/` comes from upstream, so it
   carries over as is. Check that `TextStyle._collectAttributes(in:)`,
   `BlockNode`, `InlineNode` and the `Theme` text styles still look the same.
3. Run `swift test --filter MarkdownParityTests` and look at the side-by-side
   image it writes.

Removed from the vendored copy: `Tests/`, `Examples/`, and the
snapshot-testing dependency (test target dropped from `Package.swift`).
