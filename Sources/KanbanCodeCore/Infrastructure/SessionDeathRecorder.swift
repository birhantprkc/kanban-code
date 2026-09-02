import Foundation

/// When local tmux sessions vanish between two reconcile passes without the
/// app having killed them, the cause lives outside the app: a kernel
/// memory-pressure kill, a stray `pkill`, a logout. The unified log keeps
/// those lines for a short time only, so this recorder grabs them the moment
/// the deaths are noticed and files them next to the app logs.
public enum SessionDeathRecorder {
    private static let subsystem = "session-deaths"

    /// Directory that holds one capture file per event.
    public static func capturesDirectory(kanbanHome: String) -> String {
        "\(kanbanHome)/logs/session-deaths"
    }

    /// Fire-and-forget: writes `<dir>/<timestamp>.txt` with the vanished
    /// session names, the kernel/kill lines of the last minutes of the
    /// unified log, and the biggest processes still alive.
    public static func capture(vanished: [String], kanbanHome: String) {
        Task.detached(priority: .utility) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let directory = capturesDirectory(kanbanHome: kanbanHome)
            let path = "\(directory)/\(stamp).txt"
            var report = "tmux sessions vanished: \(vanished.joined(separator: ", "))\n\n"

            report += "== unified log (kill/memorystatus, last 5m) ==\n"
            let predicate = "eventMessage CONTAINS[c] \"memorystatus\" OR eventMessage CONTAINS[c] \"jetsam\" OR (process == \"kernel\" AND eventMessage CONTAINS[c] \"kill\") OR eventMessage CONTAINS[c] \"exited due to signal\""
            let logLines = (try? await ShellCommand.run(
                "/usr/bin/log",
                arguments: ["show", "--last", "5m", "--style", "compact", "--predicate", predicate],
                timeout: 60
            ))?.stdout ?? "(log show failed or empty)"
            report += logLines + "\n"

            report += "== top processes by rss ==\n"
            let ps = (try? await ShellCommand.run(
                "/bin/sh",
                arguments: ["-c", "ps axo pid,ppid,rss,command | sort -k3 -rn | head -40"],
                timeout: 30
            ))?.stdout ?? "(ps failed)"
            report += ps

            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
            let sawKiller = logLines.contains("memorystatus") || logLines.contains("exited due to signal")
            KanbanCodeLog.warn(subsystem, "captured \(path) (kill evidence in unified log: \(sawKiller ? "yes" : "no"))")
        }
    }
}
