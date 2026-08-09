import KanbanCodeCore
import SwiftUI

/// The bar along the bottom of the board that reports what just happened.
///
/// Everything used to be posted as an error, so "copied to clipboard" arrived
/// wearing the same orange warning triangle as a failed launch. The kind picks
/// the symbol and the colour.
struct NoticeBanner: View {
    let notice: Notice
    let onDismiss: () -> Void

    private var symbol: String {
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
            Image(systemName: self.symbol)
                .font(.app(.title3))
                .foregroundStyle(self.tint.opacity(0.8))
            Text(self.notice.message)
                .font(.app(.body, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss", action: self.onDismiss)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        // No Spacer and no width of its own, so it takes the width of the
        // message and its alignment does the centring. Stretched to fill, a
        // centred banner would just be a bar with the text back on the left.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
