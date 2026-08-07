# swift-markdown-ui (vendored fork)

Upstream: https://github.com/gonzalezreal/swift-markdown-ui
Forked at: v2.4.1 (`5f613358148239d0292c0cef674a3c2314737f9e`)
License: MIT, see `LICENSE` (unchanged, copyright the original authors)

## Why it is vendored

Chat messages need a drag selection that runs across the whole message.
Upstream renders every block as its own SwiftUI view inside a `VStack`
(`Views/Blocks/BlockSequence.swift`), and SwiftUI text selection cannot span
sibling views, so a selection stops at the first block boundary. Fixing that
means changing how blocks are composed, which has no upstream extension point.

Rendering must stay identical to upstream: it is the look the app already has.

## Local changes

Each change is marked with a `// kanban-code:` comment so a future version
bump can find them.

- `Views/Blocks/BlockSequence.swift` — coalesce consecutive text-only blocks
  (paragraphs, headings, lists, quotes) into a single `Text` so a selection
  can cross them. Blocks that cannot be part of a `Text` (tables, code blocks,
  images) keep their own view.

## Upgrading

1. Diff the new upstream tag against `5f61335`.
2. Re-apply the `// kanban-code:` hunks.
3. Verify chat rendering is unchanged and that a drag still crosses blocks.

Removed from the vendored copy: `Tests/`, `Examples/`, and the
snapshot-testing dependency (test target dropped from `Package.swift`).
