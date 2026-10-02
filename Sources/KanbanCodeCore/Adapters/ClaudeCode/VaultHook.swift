import Foundation

/// The Claude Code PreToolUse hook of the vault: a Bash command run in a
/// project that has a `.env.vault` first loads the vault env (`kv hook`
/// rewrites it). The script finds no `.env.vault` in a few stat calls and
/// exits, so other projects pay nothing.
public enum VaultHook {
    public static let marker = ".kanban-code/vault-hook.sh"

    public static var scriptPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(marker)
    }

    public static let scriptContent = """
    #!/bin/sh
    # Installed by Kanban Code: Claude Code PreToolUse hook for Bash.
    # In a project with a .env.vault, `kv hook` rewrites the command to load
    # the vault env first; anywhere else this exits without output.
    d="$PWD"
    while [ -n "$d" ]; do
      if [ -f "$d/.env.vault" ]; then
        kv="$HOME/.local/bin/kv"
        [ -x "$kv" ] || kv="$(command -v kv)" || exit 0
        exec "$kv" hook
      fi
      if [ -e "$d/.git" ] || [ "$d" = "$HOME" ] || [ "$d" = "/" ]; then exit 0; fi
      d=$(dirname "$d")
    done
    exit 0

    """

    /// Installs it when the Kanban Code hooks of Claude Code are installed.
    public static func installWhereHooked() {
        guard HookManager.isInstalled(for: .claude) else { return }
        if (try? install()) == true {
            KanbanCodeLog.info("hooks", "installed the vault Bash hook")
        }
    }

    /// Writes the script and adds the hook to the Claude settings when
    /// missing. Returns whether anything changed.
    @discardableResult
    public static func install(settingsPath: String? = nil, scriptPath: String? = nil) throws -> Bool {
        let script = scriptPath ?? Self.scriptPath
        var changed = false
        if (try? String(contentsOfFile: script, encoding: .utf8)) != scriptContent {
            try FileManager.default.createDirectory(atPath: (script as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try scriptContent.write(toFile: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
            changed = true
        }
        let path = settingsPath ?? HookManager.defaultSettingsPath(for: .claude)
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return changed }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let present = groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
        guard !present else { return changed }
        groups.append(["matcher": "Bash", "hooks": [["type": "command", "command": script, "timeout": 900]]])
        hooks["PreToolUse"] = groups
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        return true
    }
}
