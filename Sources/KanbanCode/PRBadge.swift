import SwiftUI
import KanbanCodeCore

/// Displays a PR number in a colored pill badge.
/// When status is known, the color reflects the status. When nil, uses purple.
struct PRBadge: View {
    let status: PRStatus?
    let prNumber: Int
    var unresolvedThreads: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            if status == .approved {
                Image(systemName: "checkmark")
                    .font(.app(size: 8, weight: .bold))
            }
            Text(verbatim: "#\(prNumber)")
                .font(.app(size: 10, weight: .medium, design: .rounded))
            if unresolvedThreads > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "bubble.left")
                        .font(.app(size: 7))
                    Text(verbatim: "\(unresolvedThreads)")
                        .font(.app(size: 9, weight: .medium))
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(badgeColor.opacity(0.15)))
        .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        guard let status else { return .purple }
        return switch status {
        case .failing: .red
        case .unresolved: .orange
        case .changesRequested: .orange
        case .reviewNeeded: .blue
        case .pendingCI: .yellow
        case .approved: .green
        case .merged: .purple
        case .closed: .secondary
        }
    }
}

extension Collection where Element == PRLink {
    var sortedByPRNumber: [PRLink] {
        sorted {
            if $0.number != $1.number { return $0.number < $1.number }
            return ($0.url ?? "") < ($1.url ?? "")
        }
    }
}

struct PRBadgeStrip: View {
    let prLinks: [PRLink]
    var githubBaseURL: String?
    var projectPath: String?
    var maxWidth: CGFloat?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(prLinks.sortedByPRNumber, id: \.number) { pr in
                    PRBadgeButton(pr: pr, githubBaseURL: githubBaseURL, projectPath: projectPath)
                }
            }
        }
        .frame(maxWidth: maxWidth)
    }
}

struct PRBadgeButton: View {
    let pr: PRLink
    var githubBaseURL: String?
    var projectPath: String?

    var body: some View {
        Button {
            openPullRequest()
        } label: {
            PRBadge(
                status: pr.status,
                prNumber: pr.number,
                unresolvedThreads: pr.unresolvedThreads ?? 0
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        var parts = ["Open PR #\(pr.number)"]
        if let status = pr.status {
            parts.append(status.rawValue)
        }
        if let title = pr.title, !title.isEmpty {
            parts.append(title)
        }
        return parts.joined(separator: " - ")
    }

    private func openPullRequest() {
        if let url = resolvedPRURL(pr, githubBaseURL: githubBaseURL) {
            NSWorkspace.shared.open(url)
            return
        }

        guard let projectPath else { return }
        Task {
            guard let base = await GitRemoteResolver.shared.githubBaseURL(for: projectPath),
                  let url = URL(string: GitRemoteResolver.prURL(base: base, number: pr.number)) else {
                return
            }
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
