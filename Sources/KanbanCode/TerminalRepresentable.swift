import SwiftUI
import AppKit
import SwiftTerm
import KanbanCodeCore

// MARK: - Batched terminal view

/// Subclass that batches incoming pty data before feeding it to the terminal.
/// SwiftTerm's default path feeds each pty read (often tiny chunks) individually,
/// triggering a display update per chunk. This batches all data arriving within
/// a short window into a single feed, dramatically reducing redraws during
/// tmux resize/repaint and making scrolling feel instant like Warp.
///
/// LocalProcess dispatches each read via dispatchQueue.sync, so plain
/// DispatchQueue.main.async runs between chunks (FIFO). We use asyncAfter
/// with a short delay so multiple chunks accumulate before flushing.
final class BatchedTerminalView: LocalProcessTerminalView {
    private var pendingData: [UInt8] = []
    private var flushScheduled = false
    private var lastPendingDataWarningAt: CFTimeInterval = 0

    // Strategy: for small interactive responses (typing, cursor moves), render
    // immediately. For heavy streaming (Claude output), batch and drop frames.
    private static let batchDelay: DispatchTimeInterval = .milliseconds(32)  // 2 frames
    private static let chunkSize = 16 * 1024
    private static let maxBlockSeconds: Double = 0.008  // 8ms budget

    // Keep the last 32KB — enough for a full screen repaint with escape sequences.
    private static let keepBytes = 32 * 1024

    /// Threshold: data chunks smaller than this are interactive (typing, cursor moves)
    /// and should be rendered immediately without batching delay.
    private static let interactiveThreshold = 256

    private var pendingOffset = 0
    private var scheduledFlushTime: UInt64 = 0

    /// When true, disables aggressive frame dropping (copy-mode, interactive scrolling).
    var passthroughMode = false

    // Stats collection
    private var statsReceiveCount = 0
    private var statsReceiveBytes = 0
    private var statsFlushCount = 0
    private var statsFeedCalls = 0
    private var statsFeedBytes = 0
    private var statsFeedTimeMs: Double = 0
    private var statsMaxFeedMs: Double = 0
    private var statsDropCount = 0
    private var statsDropBytes = 0
    private var statsYieldCount = 0
    private var statsMaxBacklog = 0
    private var statsStartTime = CACurrentMediaTime()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        pendingData.append(contentsOf: slice)
        statsReceiveCount += 1
        statsReceiveBytes += slice.count
        if pendingData.count - pendingOffset > statsMaxBacklog {
            statsMaxBacklog = pendingData.count - pendingOffset
        }

        let totalPending = pendingData.count - pendingOffset
        if totalPending > 8 * 1024 * 1024 {
            let now = CACurrentMediaTime()
            if now - lastPendingDataWarningAt > 10 {
                lastPendingDataWarningAt = now
                KanbanCodeLog.warn(
                    "memory-context",
                    "terminal pendingData=\(totalPending / 1024)KiB passthrough=\(passthroughMode)"
                )
            }
        }

        // Small chunks (typing, cursor moves): feed directly on this main-thread
        // call — zero scheduling overhead for instant keystroke response.
        // Large chunks (Claude streaming): batch to avoid frame-per-byte overhead.
        if totalPending <= Self.interactiveThreshold && !flushScheduled {
            // Feed directly — we're already on main thread (LocalProcess dispatches here).
            // This avoids DispatchQueue.main.async latency from pending SwiftUI layout work.
            statsFlushCount += 1
            statsFeedCalls += 1
            statsFeedBytes += totalPending
            let chunk = pendingData[pendingOffset...]
            feed(byteArray: chunk)
            pendingData.removeAll(keepingCapacity: true)
            pendingOffset = 0
        } else {
            // Batched: reset the flush timer on every data arrival.
            let now = DispatchTime.now().uptimeNanoseconds
            let delay: UInt64 = passthroughMode ? 8_000_000 : 32_000_000 // 8ms or 32ms
            scheduledFlushTime = now + delay

            if !flushScheduled {
                flushScheduled = true
                let deadline: DispatchTimeInterval = passthroughMode ? .milliseconds(8) : Self.batchDelay
                DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
                    self?.checkAndProcess()
                }
            }
        }
    }

    /// Only process if enough time has passed since the last data arrival.
    /// If data is still flowing, reschedule.
    private func checkAndProcess() {
        let now = DispatchTime.now().uptimeNanoseconds
        if now < scheduledFlushTime {
            // Data arrived recently — wait more
            DispatchQueue.main.asyncAfter(
                deadline: DispatchTime(uptimeNanoseconds: scheduledFlushTime)
            ) { [weak self] in
                self?.checkAndProcess()
            }
            return
        }
        processNextChunk()
    }

    private func processNextChunk() {
        guard pendingOffset < pendingData.count else {
            pendingData.removeAll(keepingCapacity: true)
            pendingOffset = 0
            flushScheduled = false
            return
        }

        // In normal mode, skip to the tail — only the final screen state matters.
        // In passthrough mode (copy-mode), render everything for smooth scrolling.
        let backlog = pendingData.count - pendingOffset
        if !passthroughMode && backlog > Self.keepBytes {
            var cutPoint = pendingData.count - Self.keepBytes
            let scanLimit = min(cutPoint + 1024, pendingData.count)
            while cutPoint < scanLimit && pendingData[cutPoint] != 0x0A { cutPoint += 1 }
            if cutPoint < scanLimit { cutPoint += 1 }
            if cutPoint > pendingOffset {
                statsDropCount += 1
                statsDropBytes += cutPoint - pendingOffset
                pendingOffset = cutPoint
            }
        }

        statsFlushCount += 1
        let start = CACurrentMediaTime()

        while pendingOffset < pendingData.count {
            let remaining = pendingData.count - pendingOffset
            let count = min(Self.chunkSize, remaining)
            let chunk = pendingData[pendingOffset..<(pendingOffset + count)]

            let feedStart = CACurrentMediaTime()
            feed(byteArray: chunk)
            let feedMs = (CACurrentMediaTime() - feedStart) * 1000
            statsFeedCalls += 1
            statsFeedBytes += count
            statsFeedTimeMs += feedMs
            if feedMs > statsMaxFeedMs { statsMaxFeedMs = feedMs }

            pendingOffset += count

            if pendingOffset < pendingData.count && CACurrentMediaTime() - start > Self.maxBlockSeconds {
                statsYieldCount += 1
                DispatchQueue.main.async { [weak self] in
                    self?.processNextChunk()
                }
                return
            }
        }

        pendingData.removeAll(keepingCapacity: true)
        pendingOffset = 0
        flushScheduled = false

        // Print stats every 10 seconds — file I/O on background queue to avoid hitches
        let elapsed = CACurrentMediaTime() - statsStartTime
        if elapsed > 10 {
            let avgFeedMs = statsFeedCalls > 0 ? statsFeedTimeMs / Double(statsFeedCalls) : 0
            let line = String(format: "[TermStats] %.0fs | recv: %d calls %dKB | flush: %d | feed: %d calls %dKB avg:%.2fms max:%.1fms | yields: %d | maxBacklog: %dKB\n",
                  elapsed, statsReceiveCount, statsReceiveBytes/1024,
                  statsFlushCount, statsFeedCalls, statsFeedBytes/1024,
                  avgFeedMs, statsMaxFeedMs, statsYieldCount,
                  statsMaxBacklog/1024)
            DispatchQueue.global(qos: .utility).async {
                let logPath = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs/terminal-stats.log")
                if let data = line.data(using: .utf8) {
                    if let fh = FileHandle(forWritingAtPath: logPath) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        try? fh.close()
                    } else {
                        try? data.write(to: URL(fileURLWithPath: logPath))
                    }
                }
            }
            // Reset
            statsReceiveCount = 0; statsReceiveBytes = 0; statsFlushCount = 0
            statsFeedCalls = 0; statsFeedBytes = 0; statsFeedTimeMs = 0
            statsMaxFeedMs = 0; statsYieldCount = 0; statsMaxBacklog = 0
            statsDropCount = 0; statsDropBytes = 0; statsStartTime = CACurrentMediaTime()
        }
    }

    // MARK: - Paste fix

    /// Override paste to always send bracketed paste codes. With our async+dropping
    /// batching, the escape sequence that enables bracketedPasteMode may be processed
    /// late, causing terminal.bracketedPasteMode to be false when the user pastes.
    /// Claude Code always expects bracketed paste for image detection.
    override func paste(_ sender: Any) {
        let clipboard = NSPasteboard.general
        let text = clipboard.string(forType: .string) ?? ""
        // Always send bracketed paste codes — Claude Code needs them for image detection.
        // Raw bytes for \e[200~ and \e[201~ to avoid Swift 6 concurrency issues
        // with EscapeSequences static properties.
        let pasteStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] // \e[200~
        let pasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]   // \e[201~
        send(data: pasteStart[0...])
        if !text.isEmpty {
            send(txt: text)
        }
        send(data: pasteEnd[0...])
    }

    // MARK: - Cmd+hover URL detection

    /// GitHub base URL for the card's project (e.g. "https://github.com/owner/repo").
    /// Set by TerminalContainerNSView when the terminal is shown.
    var githubBaseURL: String?

    /// Currently highlighted URL range for underline drawing.
    private var highlightedURL: (screenRow: Int, colStart: Int, colEnd: Int, url: String)?
    private var urlHighlightLayer: CAShapeLayer?
    private var isCommandHeld = false
    private var urlEventMonitor: Any?

    func installURLMonitor() {
        guard urlEventMonitor == nil else { return }
        urlEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .mouseMoved, .leftMouseUp]
        ) { [weak self] event in
            guard let self,
                  !self.isHidden,
                  self.window == event.window else { return event }
            // For mouse events, check the mouse is actually over this view
            if event.type != .flagsChanged {
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else {
                    // Mouse left this terminal — clear any highlight
                    if self.highlightedURL != nil { self.clearURLHighlight() }
                    return event
                }
            }
            return self.handleURLEvent(event)
        }
    }

    func removeURLMonitor() {
        if let monitor = urlEventMonitor {
            NSEvent.removeMonitor(monitor)
            urlEventMonitor = nil
        }
        clearURLHighlight()
    }

    private func handleURLEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            isCommandHeld = event.modifierFlags.contains(.command)
            if isCommandHeld {
                let pos = screenPosition(from: event)
                updateURLHighlight(col: pos.col, screenRow: pos.screenRow)
            } else {
                clearURLHighlight()
            }
            return event

        case .mouseMoved:
            if isCommandHeld {
                let pos = screenPosition(from: event)
                updateURLHighlight(col: pos.col, screenRow: pos.screenRow)
            }
            return event

        case .leftMouseUp:
            if event.modifierFlags.contains(.command) {
                let pos = screenPosition(from: event)
                if let detected = detectURL(col: pos.col, screenRow: pos.screenRow) {
                    clearURLHighlight()
                    let raw = detected.url
                    // File paths: use URL(fileURLWithPath:) to handle +, spaces, etc.
                    if raw.hasPrefix("/"), FileManager.default.fileExists(atPath: raw) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: raw))
                    } else if let url = URL(string: raw) {
                        NSWorkspace.shared.open(url)
                    }
                    return nil // consume the event
                }
            }
            return event

        default:
            return event
        }
    }

    /// Cell dimensions matching SwiftTerm's internal calculation.
    private var cellSize: CGSize {
        let f = font
        let glyph = f.glyph(withName: "W")
        let cw = f.advancement(forGlyph: glyph).width
        let ch = ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
        return CGSize(width: max(1, cw), height: max(1, ch))
    }

    /// Compute screen row (0-based from top) and col from mouse event.
    private func screenPosition(from event: NSEvent) -> (col: Int, screenRow: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let cols = terminal.cols
        let rows = terminal.rows
        guard cols > 0, rows > 0 else { return (0, 0) }
        let cs = cellSize
        let col = min(max(0, Int(point.x / cs.width)), cols - 1)
        let screenRow = min(max(0, Int((bounds.height - point.y) / cs.height)), rows - 1)
        return (col, screenRow)
    }

    /// Extract the URL under the cursor at the given screen position, if any.
    /// Also detects GitHub issue/PR references like `owner/repo#123` or bare `#123`.
    private func detectURL(col: Int, screenRow: Int) -> (url: String, colStart: Int, colEnd: Int)? {
        guard let line = terminal.getLine(row: screenRow) else { return nil }
        let text = line.translateToString(trimRight: true)
        guard let detection = TerminalURLDetector.detect(in: text, col: col, githubBaseURL: githubBaseURL) else {
            return nil
        }
        return (detection.url, detection.colStart, detection.colEnd)
    }

    private func updateURLHighlight(col: Int, screenRow: Int) {
        if let detected = detectURL(col: col, screenRow: screenRow) {
            if highlightedURL?.screenRow == screenRow,
               highlightedURL?.colStart == detected.colStart,
               highlightedURL?.colEnd == detected.colEnd { return }
            highlightedURL = (screenRow, detected.colStart, detected.colEnd, detected.url)
            drawURLHighlight(screenRow: screenRow, colStart: detected.colStart, colEnd: detected.colEnd)
            NSCursor.pointingHand.set()
        } else {
            clearURLHighlight()
        }
    }

    private func drawURLHighlight(screenRow: Int, colStart: Int, colEnd: Int) {
        urlHighlightLayer?.removeFromSuperlayer()
        let cs = cellSize
        let x = CGFloat(colStart) * cs.width
        // macOS origin is bottom-left; screenRow 0 = top of terminal
        let y = bounds.height - CGFloat(screenRow + 1) * cs.height
        let w = CGFloat(colEnd - colStart + 1) * cs.width

        let layer = CAShapeLayer()
        let underlineY = y + 1.0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: underlineY))
        path.addLine(to: CGPoint(x: x + w, y: underlineY))
        layer.path = path
        layer.strokeColor = NSColor.linkColor.cgColor
        layer.lineWidth = 1
        layer.fillColor = nil

        self.wantsLayer = true
        self.layer?.addSublayer(layer)
        urlHighlightLayer = layer
    }

    private func clearURLHighlight() {
        guard highlightedURL != nil else { return }
        highlightedURL = nil
        urlHighlightLayer?.removeFromSuperlayer()
        urlHighlightLayer = nil
        NSCursor.arrow.set()
    }

}

// MARK: - Terminal process cache

/// Caches tmux terminal views across drawer close/open cycles.
/// When the drawer closes, terminals are detached from the view hierarchy but kept alive.
/// When reopened, the cached terminal is reparented — no new tmux attach needed,
/// preserving scrollback and terminal state.
@MainActor
final class TerminalCache {
    static let shared = TerminalCache()
    static let defaultFontSize: CGFloat = 12
    static let fontSizeKey = "sessionDetailFontSize"

    private var terminals: [String: BatchedTerminalView] = [:]
    private var shiftEnterMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var fontSizeObserver: Any?
    private var lastLoggedTerminalCount = 0

    private var currentFontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: TerminalCache.fontSizeKey)
        return stored > 0 ? CGFloat(stored) : TerminalCache.defaultFontSize
    }()

    /// Find the active (visible) session name for the terminal under the given window point.
    /// Bypasses hitTest which can be intercepted by SwiftUI overlay views.
    /// Checks both isHidden and effective opacity (parent container may be opacity 0).
    func sessionUnderPoint(_ windowPoint: NSPoint, in window: NSWindow) -> String? {
        for (sessionName, terminal) in terminals {
            guard !terminal.isHidden,
                  terminal.window == window else { continue }
            // Check if any ancestor has opacity 0 (e.g. when browser tab is selected)
            var view: NSView? = terminal.superview
            var effectivelyHidden = false
            while let v = view {
                if v.alphaValue < 0.01 { effectivelyHidden = true; break }
                view = v.superview
            }
            guard !effectivelyHidden else { continue }
            let localPoint = terminal.convert(windowPoint, from: nil)
            if terminal.bounds.contains(localPoint) {
                return sessionName
            }
        }
        return nil
    }

    /// Tracks tmux copy-mode state per session for scroll interception.
    fileprivate var copyModeSessions: Set<String> = []

    /// Cooldown: after exiting copy-mode, ignore scroll events briefly
    /// to prevent residual momentum from re-entering copy-mode.
    fileprivate var copyModeExitTime: [String: ContinuousClock.Instant] = [:]

    private init() {
        let tmux = Self.tmuxPath

        // Intercept keyDown events in terminal views for two purposes:
        // 1. Shift+Enter → send \n instead of \r (Claude Code newline vs submit)
        // 2. Any key while in tmux copy-mode → exit copy-mode first, then let key through
        shiftEnterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let terminal = event.window?.firstResponder as? TerminalView else { return event }

            // Shift+Enter: send newline instead of carriage return
            if event.keyCode == 36, event.modifierFlags.contains(.shift) {
                terminal.send([0x0a])
                return nil
            }

            guard let self else { return event }

            // Find the session for this terminal
            var view: NSView? = terminal
            while let v = view, !(v is TerminalContainerNSView) {
                view = v.superview
            }
            guard let container = view as? TerminalContainerNSView,
                  let session = container.activeSession else { return event }

            // If in copy-mode, exit it on any non-modifier keypress.
            // Uses -X cancel (copy-mode command) — no-op if already exited, never leaks.
            if self.copyModeSessions.contains(session) {
                // Ignore keys with Cmd/Opt/Ctrl held — let the system handle them
                // (e.g. Cmd+C for copy, Cmd+V for paste).
                let modifiers = event.modifierFlags.intersection([.command, .option, .control])
                guard modifiers.isEmpty else { return event }

                self.copyModeSessions.remove(session)
                self.copyModeExitTime[session] = .now
                self.terminals[session]?.passthroughMode = false

                // Esc just dismisses scroll mode — don't forward it to the shell.
                let isEscape = event.keyCode == 53
                let chars = isEscape ? "" : (event.characters ?? "")
                Task.detached {
                    _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "cancel"])
                    if !chars.isEmpty {
                        _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, chars])
                    }
                }
                return nil // consume — key is re-sent via tmux above
            }

            return event // let the key through to the terminal
        }

        // Intercept scroll wheel events over terminal views and translate to tmux
        // copy-mode navigation. TerminalView (from SwiftTerm) consumes scrollWheel
        // events before parent views can handle them, so we intercept at the app level.
        // We check terminal bounds directly instead of using hitTest, which can be
        // intercepted by SwiftUI overlay views (e.g. inspector panel).
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard event.deltaY != 0 else { return event }

            guard let window = event.window else { return event }
            guard let session = self?.sessionUnderPoint(event.locationInWindow, in: window) else { return event }

            let inCopyMode = self?.copyModeSessions.contains(session) ?? false

            // After exiting copy-mode, ignore scroll events for 500ms
            // to prevent residual trackpad momentum from re-entering.
            if let exitTime = self?.copyModeExitTime[session],
               exitTime.duration(to: .now) < .milliseconds(500) {
                return nil // consume during cooldown
            }

            if event.deltaY > 0 {
                // Scroll UP — enter copy-mode if needed, then scroll.
                // All scroll commands use -X (copy-mode commands) so they're
                // no-ops if copy-mode has already been exited by another task.
                let lines = max(1, Int(abs(event.deltaY)))
                if !inCopyMode {
                    self?.copyModeSessions.insert(session)
                    self?.terminals[session]?.passthroughMode = true
                    Task.detached {
                        _ = try? await ShellCommand.run(tmux, arguments: ["copy-mode", "-t", session])
                        _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "-N", "\(lines)", "cursor-up"])
                    }
                } else {
                    Task.detached {
                        _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "-N", "\(lines)", "cursor-up"])
                    }
                }
            } else if inCopyMode {
                // Scroll DOWN in copy-mode.
                // -X cursor-down is a copy-mode command: no-op if copy-mode already exited.
                // No literal keys ever reach the shell, regardless of concurrent task timing.
                let lines = max(1, Int(abs(event.deltaY)))
                Task.detached {
                    _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "-N", "\(lines)", "cursor-down"])
                    try? await Task.sleep(for: .milliseconds(50))
                    let result = try? await ShellCommand.run(
                        tmux, arguments: ["display-message", "-p", "-t", session, "#{scroll_position}"]
                    )
                    if result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
                        // Only the first task to reach here proceeds (remove returns nil for duplicates).
                        let shouldExit = await MainActor.run {
                            guard TerminalCache.shared.copyModeSessions.remove(session) != nil else { return false }
                            TerminalCache.shared.copyModeExitTime[session] = .now
                            TerminalCache.shared.terminals[session]?.passthroughMode = false
                            return true
                        }
                        if shouldExit {
                            _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "cancel"])
                        }
                    }
                }
            }

            return nil // consume the event — don't let TerminalView handle it
        }

        // Observe font size changes from Settings / Cmd+Plus/Minus
        fontSizeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyFontSizeIfChanged()
            }
        }
    }

    private func applyFontSizeIfChanged() {
        let stored = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        let newSize = stored > 0 ? CGFloat(stored) : Self.defaultFontSize
        guard newSize != currentFontSize else { return }
        currentFontSize = newSize
        let font = NSFont.monospacedSystemFont(ofSize: newSize, weight: .regular)
        for terminal in terminals.values {
            terminal.font = font
        }
    }

    /// Tracks which terminals have had their process started.
    private var startedSessions: Set<String> = []

    /// Resolved tmux binary path — checked once, reused for all terminals.
    static let tmuxPath: String = ShellCommand.findExecutable("tmux") ?? "tmux"

    /// Get or create a terminal view for the given tmux session name.
    /// The process is NOT started here — call `startProcessIfNeeded` after layout
    /// so the terminal has a non-zero frame (avoids tmux SIGWINCH clear on resize from 0x0).
    func terminal(for sessionName: String, frame: NSRect) -> BatchedTerminalView {
        if let existing = terminals[sessionName] {
            return existing
        }
        let terminal = BatchedTerminalView(frame: frame)
        // Dark terminal colors matching a real terminal
        terminal.nativeBackgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1.0)
        terminal.caretColor = .systemGreen

        // Brighter ANSI palette (SwiftTerm Color uses UInt16 0-65535, multiply 0-255 by 257)
        let c = { (r: UInt16, g: UInt16, b: UInt16) in SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257) }
        terminal.installColors([
            // Standard colors (0-7)
            c(0x33, 0x33, 0x33),  // black (slightly visible)
            c(0xFF, 0x5F, 0x56),  // red
            c(0x5A, 0xF7, 0x8E),  // green
            c(0xFF, 0xD7, 0x5F),  // yellow
            c(0x57, 0xAC, 0xFF),  // blue
            c(0xFF, 0x6A, 0xC1),  // magenta
            c(0x5A, 0xF7, 0xD4),  // cyan
            c(0xE0, 0xE0, 0xE0),  // white
            // Bright colors (8-15)
            c(0x66, 0x66, 0x66),  // bright black
            c(0xFF, 0x6E, 0x67),  // bright red
            c(0x5A, 0xF7, 0x8E),  // bright green
            c(0xFF, 0xFC, 0x67),  // bright yellow
            c(0x6B, 0xC1, 0xFF),  // bright blue
            c(0xFF, 0x77, 0xD0),  // bright magenta
            c(0x5A, 0xF7, 0xD4),  // bright cyan
            c(0xFF, 0xFF, 0xFF),  // bright white
        ])

        terminal.font = NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)

        // Do NOT set autoresizingMask — we manage frame explicitly in layout()
        // to avoid intermediate sizes triggering tmux redraws during animations.
        terminal.autoresizingMask = []
        terminal.isHidden = true
        terminal.installURLMonitor()
        terminals[sessionName] = terminal
        logGrowthIfNeeded(trigger: "create session=\(sessionName)")
        return terminal
    }

    /// Start the tmux attach process if the terminal has a non-zero frame and hasn't started yet.
    func startProcessIfNeeded(for sessionName: String) {
        guard let terminal = terminals[sessionName] else { return }
        guard !startedSessions.contains(sessionName) else { return }
        guard terminal.frame.width > 0, terminal.frame.height > 0 else { return }
        startedSessions.insert(sessionName)

        let escaped = sessionName.replacingOccurrences(of: "'", with: "'\\''")
        let tmux = Self.tmuxPath
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(
            executable: userShell,
            args: ["-l", "-c", "for i in $(seq 1 50); do '\(tmux)' has-session -t '\(escaped)' 2>/dev/null && break; sleep 0.1; done; exec '\(tmux)' attach-session -t '\(escaped)'"],
            environment: nil,
            execName: nil,
            currentDirectory: nil
        )
    }

    /// Remove and terminate a specific terminal (e.g., when user kills a session).
    func remove(_ sessionName: String) {
        startedSessions.remove(sessionName)
        if let terminal = terminals.removeValue(forKey: sessionName) {
            terminal.removeURLMonitor()
            terminal.removeFromSuperview()
            terminal.terminate()
        }
    }

    /// Check if a terminal exists for this session.
    func has(_ sessionName: String) -> Bool {
        terminals[sessionName] != nil
    }

    func diagnosticSummary() -> String {
        "terminalCache terminals=\(terminals.count) started=\(startedSessions.count) copyMode=\(copyModeSessions.count) copyModeCooldowns=\(copyModeExitTime.count)"
    }

    private func logGrowthIfNeeded(trigger: String) {
        let terminalCount = terminals.count
        guard terminalCount >= 8, terminalCount != lastLoggedTerminalCount else { return }
        lastLoggedTerminalCount = terminalCount
        KanbanCodeLog.warn(
            "memory-context",
            "terminalCache grew trigger=\(trigger) terminals=\(terminalCount) started=\(startedSessions.count) copyMode=\(copyModeSessions.count)"
        )
    }

    /// Focus the terminal for a session directly (bypasses NSViewRepresentable update).
    func focusTerminal(for sessionName: String) {
        guard let terminal = terminals[sessionName] else { return }
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak terminal] in
            guard let terminal, terminal.window?.firstResponder !== terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}

// MARK: - Multi-terminal container (manages all terminals for a card)

/// A single NSViewRepresentable that manages multiple tmux terminal subviews.
/// Uses TerminalCache to persist terminals across drawer close/open cycles.
/// Terminals are created once globally and reparented as needed — never destroyed
/// just because the drawer was toggled.
struct TerminalContainerView: NSViewRepresentable, Equatable {
    /// All tmux session names to show tabs for.
    let sessions: [String]
    /// Which session is currently visible.
    let activeSession: String
    /// When true, the terminal grabs keyboard focus (user clicked a tab).
    /// When false, the terminal is shown but focus stays where it was (keyboard nav, drawer open).
    var grabFocus: Bool = false
    /// GitHub base URL for the card's project, used for resolving #123 references.
    var githubBaseURL: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Ultra-strict: only sessions matter. grabFocus changes should NOT
        // trigger updateNSView — we handle focus separately.
        lhs.sessions == rhs.sessions
            && lhs.activeSession == rhs.activeSession
    }

    func makeNSView(context: Context) -> TerminalContainerNSView {
        KanbanCodeLog.info("terminal-view", "makeNSView: sessions=\(sessions) active=\(activeSession)")
        let container = TerminalContainerNSView()
        container.githubBaseURL = githubBaseURL
        for session in sessions {
            container.ensureTerminal(for: session)
        }
        container.showTerminal(for: activeSession, grabFocus: grabFocus)
        return container
    }

    func updateNSView(_ nsView: TerminalContainerNSView, context: Context) {
        KanbanCodeLog.info("terminal-view", "updateNSView called: sessions=\(sessions) active=\(activeSession) grabFocus=\(grabFocus)")
        nsView.githubBaseURL = githubBaseURL
        // When sessions are empty (terminal not yet created), just clean up and return.
        guard !sessions.isEmpty, !activeSession.isEmpty else {
            nsView.removeTerminalsNotIn([])
            return
        }
        // Add any new sessions (idempotent — reuses cached terminals)
        for session in sessions {
            nsView.ensureTerminal(for: session)
        }
        // Remove terminals that are no longer in the list
        nsView.removeTerminalsNotIn(Set(sessions))
        // Switch visible terminal
        nsView.showTerminal(for: activeSession, grabFocus: grabFocus)
    }

    static func dismantleNSView(_ nsView: TerminalContainerNSView, coordinator: ()) {
        KanbanCodeLog.info("terminal-view", "dismantleNSView — detaching all terminals")
        // Detach terminals from this container but do NOT terminate them.
        // They live on in TerminalCache and will be reparented when the drawer reopens.
        nsView.detachAll()
    }
}

/// AppKit container that owns multiple LocalProcessTerminalView instances.
/// Uses TerminalCache for process lifecycle — terminal processes survive view teardown.
final class TerminalContainerNSView: NSView {
    private static let terminalPadding: CGFloat = 6

    /// Ordered list of session names managed by this container.
    private var managedSessions: [String] = []
    fileprivate private(set) var activeSession: String?
    /// GitHub base URL for resolving bare #123 references in terminals.
    var githubBaseURL: String? {
        didSet {
            for name in managedSessions {
                TerminalCache.shared.terminal(for: name, frame: bounds).githubBaseURL = githubBaseURL
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0).cgColor
    }

    /// Ensure a terminal for `sessionName` is attached to this container.
    func ensureTerminal(for sessionName: String) {
        guard !managedSessions.contains(sessionName) else { return }
        let terminal = TerminalCache.shared.terminal(for: sessionName, frame: bounds)
        terminal.githubBaseURL = githubBaseURL
        if terminal.superview !== self {
            terminal.removeFromSuperview()
            addSubview(terminal)
        }
        // Show immediately with old content — no hiding/alpha tricks.
        // Combined with BatchedTerminalView, any tmux redraw lands as
        // one batched update instead of visible scrolling.
        terminal.isHidden = true
        managedSessions.append(sessionName)
    }

    /// Show only the terminal for `sessionName`, hide all others.
    func showTerminal(for sessionName: String, grabFocus: Bool = false) {
        activeSession = sessionName
        for name in managedSessions {
            let terminal = TerminalCache.shared.terminal(for: name, frame: bounds)
            let isActive = (name == sessionName)
            if terminal.isHidden != !isActive {
                terminal.isHidden = !isActive
            }
            if isActive {
                disableScrollbar(on: terminal)
                if grabFocus {
                    // Try immediately, then retry after a delay for heavy cards
                    // where SwiftUI re-renders steal focus during history loading.
                    DispatchQueue.main.async { [weak self] in
                        self?.window?.makeFirstResponder(terminal)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.activeSession == sessionName,
                              self.window?.firstResponder !== terminal else { return }
                        self.window?.makeFirstResponder(terminal)
                    }
                }
            }
        }
    }

    /// Hide SwiftTerm's built-in NSScroller.
    private func disableScrollbar(on terminal: NSView) {
        for subview in terminal.subviews {
            if let scroller = subview as? NSScroller {
                scroller.isHidden = true
            }
        }
    }

    /// Remove terminals whose session names are not in `keep`.
    func removeTerminalsNotIn(_ keep: Set<String>) {
        let toRemove = managedSessions.filter { !keep.contains($0) }
        for name in toRemove {
            TerminalCache.shared.remove(name)
            managedSessions.removeAll { $0 == name }
        }
    }

    /// Detach all terminals from this container without terminating them.
    func detachAll() {
        for sub in subviews {
            sub.removeFromSuperview()
        }
        managedSessions.removeAll()
        activeSession = nil
    }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: Self.terminalPadding, dy: Self.terminalPadding)
        guard inset.width > 0, inset.height > 0 else { return }

        for sub in subviews {
            // Only resize if the change is >= 1px to avoid tmux SIGWINCH
            // from sub-pixel layout jitter during background state updates.
            let delta = abs(sub.frame.origin.x - inset.origin.x)
                + abs(sub.frame.origin.y - inset.origin.y)
                + abs(sub.frame.width - inset.width)
                + abs(sub.frame.height - inset.height)
            if delta >= 1.0 {
                KanbanCodeLog.info("terminal-layout", "RESIZE delta=\(String(format: "%.1f", delta))px old=\(sub.frame) new=\(inset) sessions=\(managedSessions)")
                sub.frame = inset
            }
        }

        for name in managedSessions {
            TerminalCache.shared.startProcessIfNeeded(for: name)
        }
    }

}
