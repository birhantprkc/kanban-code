import KanbanCodeCore
import SwiftUI

/// Counts a banner down to its dismissal, pausing while it is being attended to.
///
/// Separate from the view so the timing is something you can run in a test
/// rather than something you have to watch.
@MainActor
struct NoticeCountdown {
    /// Long enough to read a line, short enough not to sit over the terminal.
    var lifetime: Duration = .seconds(4)
    var tick: Duration = .milliseconds(100)
    /// Whether the banner is being attended to right now, in which case the
    /// clock stops. The one moment you want it to stay is while you are reading
    /// it or reaching for the close button.
    let isHeld: () -> Bool

    /// Runs the clock down. Returns false if it was cancelled or hit `limit`
    /// first, which means nothing should be dismissed.
    func run(limit: Duration? = nil) async -> Bool {
        var remaining = self.lifetime
        var spent = Duration.zero
        while remaining > .zero {
            do { try await Task.sleep(for: self.tick) } catch { return false }
            spent += self.tick
            if let limit, spent >= limit { return false }
            guard !self.isHeld() else { continue }
            remaining -= self.tick
        }
        return true
    }
}

/// The banner along the bottom of the window that reports what just happened.
///
/// Everything used to be posted as an error, so "copied to clipboard" arrived
/// wearing the same orange warning triangle as a failed launch. The kind picks
/// the symbol and the colour.
struct NoticeBanner: View {
    let notice: Notice
    let onDismiss: () -> Void

    @State private var isHovering = false

    var symbolName: String {
        switch self.notice.kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch self.notice.kind {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: self.symbolName)
                .font(.app(.title3))
                .foregroundStyle(self.tint)
            Text(self.notice.message)
                .font(.app(.body, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: self.onDismiss) {
                Image(systemName: "xmark")
                    .font(.app(.caption, weight: .semibold))
                    .foregroundStyle(self.isHovering ? .primary : .secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        // No Spacer and no width of its own, so it takes the width of the
        // message and its alignment does the centring. Stretched to fill, a
        // centred banner would just be a bar with the text back on the left.
        //
        // Opaque, not a material: this lands over the terminal, and a
        // translucent panel over a dark pane reads as a smear rather than as
        // something sitting on top of it.
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onHover { self.isHovering = $0 }
        .task(id: self.notice) {
            let countdown = NoticeCountdown(isHeld: { self.isHovering })
            if await countdown.run() { self.onDismiss() }
        }
    }
}
