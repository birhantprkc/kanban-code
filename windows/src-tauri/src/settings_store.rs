use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::OnceLock;
use tokio::fs;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub path: String,
    pub name: Option<String>,
    pub github_filter: Option<String>,
    pub repo_root: Option<String>,
    /// Per-project prompt prefix. When set, overrides Settings.promptTemplate
    /// for tasks created against this project. Optional.
    #[serde(default)]
    pub prompt_template: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct GlobalViewSettings {
    #[serde(default)]
    pub excluded_paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHubSettings {
    #[serde(default = "default_gh_filter")]
    pub default_filter: String,
    #[serde(default = "default_poll_interval")]
    pub poll_interval_seconds: u64,
    #[serde(default = "default_merge_command")]
    pub merge_command: String,
}

fn default_gh_filter() -> String {
    "assignee:@me is:open".to_string()
}
fn default_poll_interval() -> u64 {
    60
}
fn default_merge_command() -> String {
    "gh pr merge ${number} --squash --delete-branch".to_string()
}

impl Default for GitHubSettings {
    fn default() -> Self {
        Self {
            default_filter: default_gh_filter(),
            poll_interval_seconds: default_poll_interval(),
            merge_command: default_merge_command(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationSettings {
    #[serde(default = "default_true")]
    pub notifications_enabled: bool,
    #[serde(default)]
    pub pushover_enabled: bool,
    pub pushover_token: Option<String>,
    pub pushover_user_key: Option<String>,
    #[serde(default)]
    pub render_markdown_image: bool,
}

fn default_true() -> bool {
    true
}

impl Default for NotificationSettings {
    fn default() -> Self {
        Self {
            notifications_enabled: true,
            pushover_enabled: false,
            pushover_token: None,
            pushover_user_key: None,
            render_markdown_image: false,
        }
    }
}

/// Byte-compatible with macOS `RemoteSettings` (Sources/.../SettingsStore.swift).
/// Field names — `host`, `remotePath`, `localPath`, `syncIgnores` — match exactly
/// so a settings.json moved between Mac and Windows keeps working.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct RemoteSettings {
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub remote_path: String,
    #[serde(default)]
    pub local_path: String,
    /// nil = use mutagen::default_ignores()
    #[serde(default)]
    pub sync_ignores: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTimeoutSettings {
    #[serde(default = "default_timeout_minutes")]
    pub active_threshold_minutes: u64,
}

fn default_timeout_minutes() -> u64 {
    1440
}

impl Default for SessionTimeoutSettings {
    fn default() -> Self {
        Self {
            active_threshold_minutes: default_timeout_minutes(),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SelfCompactAction {
    QueuePrompt,
    CompactNow,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SelfCompactRule {
    pub id: String,
    pub threshold_tokens: i64,
    pub action: SelfCompactAction,
    pub message: String,
}

impl SelfCompactRule {
    /// Byte-compatible defaults with macOS SelfCompactRule.defaults so a
    /// settings.json round-tripped between platforms keeps the same rule set.
    pub fn defaults() -> Vec<Self> {
        vec![
            Self {
                id: "ctx-500k".into(),
                threshold_tokens: 500_000,
                action: SelfCompactAction::QueuePrompt,
                message: "You are above the 500k context limit. Whenever it is convenient, use the kanban CLI to send yourself a self-compact.".into(),
            },
            Self {
                id: "ctx-600k".into(),
                threshold_tokens: 600_000,
                action: SelfCompactAction::QueuePrompt,
                message: "You are above the 600k context limit. Please compact yourself soon using the kanban CLI self-compact command.".into(),
            },
            Self {
                id: "ctx-700k".into(),
                threshold_tokens: 700_000,
                action: SelfCompactAction::QueuePrompt,
                message: "You are above the 700k context limit. Compact yourself IMMEDIATELY using the kanban CLI self-compact command.".into(),
            },
            Self {
                id: "ctx-750k".into(),
                threshold_tokens: 750_000,
                action: SelfCompactAction::CompactNow,
                message: "/compact".into(),
            },
        ]
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelfCompactSettings {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_self_compact_poll")]
    pub poll_interval_seconds: u64,
    #[serde(default = "SelfCompactRule::defaults")]
    pub rules: Vec<SelfCompactRule>,
}

fn default_self_compact_poll() -> u64 {
    30
}

impl Default for SelfCompactSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            poll_interval_seconds: default_self_compact_poll(),
            rules: SelfCompactRule::defaults(),
        }
    }
}

/// Named API service binding for a coding assistant. Wraps the CLI with an
/// optional launcher prefix (e.g. `ollama launch`), a `--model` value, and
/// an optional base URL that becomes `ANTHROPIC_BASE_URL` (or the assistant's
/// equivalent) at launch time. Byte-compatible with macOS APIService.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct APIService {
    pub id: String,
    pub name: String,
    /// CodingAssistant raw value ("claude", "gemini", …). Stored as a string
    /// so an unknown id from a future macOS-built settings.json still parses.
    pub assistant: String,
    /// Shell command prepended before the assistant CLI. `None` = call the
    /// CLI directly. Example: `Some("ollama launch")`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launcher_prefix: Option<String>,
    /// Value passed to `--model`. `None` omits the flag entirely.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_flag: Option<String>,
    /// Base URL injected as an env var at launch (e.g. `ANTHROPIC_BASE_URL`).
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "baseURL")]
    pub base_url: Option<String>,
}

impl APIService {
    /// Whether a `--` separator is required before the assistant's own flags.
    /// Mirrors macOS APIService.needsSeparator.
    pub fn needs_separator(&self) -> bool {
        self.launcher_prefix.is_some() || self.model_flag.is_some()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default)]
    pub projects: Vec<Project>,
    #[serde(default)]
    pub global_view: GlobalViewSettings,
    #[serde(default)]
    pub github: GitHubSettings,
    #[serde(default)]
    pub notifications: NotificationSettings,
    #[serde(default)]
    pub session_timeout: SessionTimeoutSettings,
    #[serde(default)]
    pub prompt_template: String,
    #[serde(default = "default_issue_template")]
    pub github_issue_prompt_template: String,
    #[serde(default)]
    pub has_completed_onboarding: bool,
    /// Editor command (e.g. "code", "cursor", "nvim")
    #[serde(default)]
    pub editor: String,
    /// Terminal font size (8-24)
    #[serde(default = "default_terminal_font_size")]
    pub terminal_font_size: u32,
    /// Font size for the History tab transcript view (8-20). Matches the
    /// macOS `sessionDetailFontSize` AppStorage so a settings round-trip
    /// between platforms preserves the preference.
    #[serde(default = "default_session_detail_font_size")]
    pub session_detail_font_size: u32,
    /// Shell command used by the embedded terminal — space-separated tokens.
    /// Defaults to `cmd.exe` for a native Windows experience. Set to
    /// `wsl.exe` (or `pwsh.exe -NoLogo`, etc.) to run Claude in a different
    /// shell. The first token is the executable; remaining tokens are args.
    #[serde(default = "default_terminal_shell")]
    pub terminal_shell: String,
    #[serde(default)]
    pub remote: Option<RemoteSettings>,
    /// Automatic context-limit guard for Claude sessions. Byte-compatible
    /// with macOS Settings.selfCompact — a settings.json moved between Mac
    /// and Windows keeps its rule set.
    #[serde(default)]
    pub self_compact: SelfCompactSettings,
    /// Named API service bindings — see APIService for shape. Byte-compatible
    /// with macOS Settings.apiServices.
    #[serde(default)]
    pub api_services: Vec<APIService>,
    /// Maps `CodingAssistant.rawValue` → `APIService.id` for the per-assistant
    /// default service. Matches macOS Settings.defaultAPIServiceIds.
    #[serde(default)]
    pub default_api_service_ids: HashMap<String, String>,
}

impl Settings {
    /// Resolves the APIService to use for a card launch. Resolution order:
    /// per-card override → per-assistant default → none. Returns `None` when
    /// no binding exists or the referenced id no longer points at anything
    /// (e.g. the service was deleted but a card's override is stale).
    pub fn resolve_api_service(
        &self,
        card_override: Option<&str>,
        assistant_id: &str,
    ) -> Option<&APIService> {
        // Per-card override wins. Stale override → fall through to default
        // so deleting a service doesn't leave cards unlaunchable.
        if let Some(id) = card_override {
            if let Some(svc) = self.api_services.iter().find(|s| s.id == id) {
                return Some(svc);
            }
        }
        let default_id = self.default_api_service_ids.get(assistant_id)?;
        self.api_services.iter().find(|s| &s.id == default_id)
    }
}

fn default_terminal_font_size() -> u32 {
    15
}

fn default_session_detail_font_size() -> u32 {
    12
}

fn default_terminal_shell() -> String {
    #[cfg(target_os = "windows")]
    {
        "cmd.exe".to_string()
    }
    #[cfg(not(target_os = "windows"))]
    {
        "bash".to_string()
    }
}

fn default_issue_template() -> String {
    "#${number}: ${title}\n\n${body}".to_string()
}

/// First time the settings file is read on this process, peek at the raw JSON
/// to see whether it came from the macOS app. macOS doesn't write the
/// Windows-only keys (`terminalShell`, `terminalFontSize`, `editor`); when
/// they're absent serde's `#[serde(default)]` silently backfills the Windows
/// defaults. We use `terminalShell` alone as the sentinel — adding more keys
/// to the AND would just create false negatives if a Windows user explicitly
/// cleared one. A new Windows-only field does NOT need to be added to the
/// check; just keep this comment up to date.
///
/// No `schema_version` field is added — that would break the macOS byte-compat
/// invariant (sortedKeys+prettyPrinted JSON shared with the Swift app).
fn log_cross_platform_backfill_once(raw: &[u8]) {
    static LOGGED: OnceLock<()> = OnceLock::new();
    if LOGGED.get().is_some() {
        return;
    }
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(raw) else { return };
    let obj = match v.as_object() {
        Some(o) => o,
        None => return,
    };
    if !obj.contains_key("terminalShell") {
        let _ = LOGGED.set(());
        crate::logging::info(
            "settings",
            "settings.json missing terminalShell/terminalFontSize — backfilling Windows defaults (file appears to originate from macOS)",
        );
    }
}

pub struct SettingsStore {
    file_path: PathBuf,
}

impl SettingsStore {
    pub fn new(base_path: Option<PathBuf>) -> Self {
        let base = base_path
            .unwrap_or_else(|| crate::coordination_store::kanban_data_dir());
        Self {
            file_path: base.join("settings.json"),
        }
    }

    pub async fn read(&self) -> Result<Settings> {
        if !self.file_path.exists() {
            let defaults = Settings::default();
            self.write(&defaults).await?;
            return Ok(defaults);
        }
        let data = fs::read(&self.file_path).await.context("read settings.json")?;
        log_cross_platform_backfill_once(&data);
        let settings: Settings = serde_json::from_slice(&data).unwrap_or_default();
        Ok(settings)
    }

    pub async fn write(&self, settings: &Settings) -> Result<()> {
        if let Some(parent) = self.file_path.parent() {
            fs::create_dir_all(parent).await.context("create settings dir")?;
        }
        let data = serde_json::to_vec_pretty(settings).context("serialize settings")?;
        let tmp = self.file_path.with_extension("json.tmp");
        fs::write(&tmp, &data).await.context("write settings tmp")?;
        fs::rename(&tmp, &self.file_path).await.context("rename settings tmp")?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn svc(id: &str, assistant: &str) -> APIService {
        APIService {
            id: id.into(),
            name: format!("svc-{id}"),
            assistant: assistant.into(),
            launcher_prefix: None,
            model_flag: None,
            base_url: None,
        }
    }

    #[test]
    fn resolve_prefers_card_override() {
        let mut s = Settings::default();
        s.api_services = vec![svc("a", "claude"), svc("b", "claude")];
        s.default_api_service_ids.insert("claude".into(), "a".into());
        let resolved = s.resolve_api_service(Some("b"), "claude").unwrap();
        assert_eq!(resolved.id, "b");
    }

    #[test]
    fn resolve_falls_back_to_per_assistant_default_when_no_override() {
        let mut s = Settings::default();
        s.api_services = vec![svc("a", "claude")];
        s.default_api_service_ids.insert("claude".into(), "a".into());
        let resolved = s.resolve_api_service(None, "claude").unwrap();
        assert_eq!(resolved.id, "a");
    }

    #[test]
    fn resolve_stale_override_falls_back_to_default_instead_of_failing() {
        // A card holds an override pointing at a deleted service. Without the
        // fallback the card would be unlaunchable; with it the per-assistant
        // default takes over. Matches macOS resolveAPIService.
        let mut s = Settings::default();
        s.api_services = vec![svc("kept", "claude")];
        s.default_api_service_ids.insert("claude".into(), "kept".into());
        let resolved = s.resolve_api_service(Some("deleted"), "claude").unwrap();
        assert_eq!(resolved.id, "kept");
    }

    #[test]
    fn resolve_returns_none_when_no_default_and_no_override() {
        let s = Settings::default();
        assert!(s.resolve_api_service(None, "claude").is_none());
    }

    #[test]
    fn settings_round_trip_preserves_api_services_and_defaults() {
        let mut s = Settings::default();
        s.api_services = vec![APIService {
            id: "ollama-1".into(),
            name: "Local Ollama".into(),
            assistant: "claude".into(),
            launcher_prefix: Some("ollama launch".into()),
            model_flag: Some("qwen3-coder-next:cloud".into()),
            base_url: Some("http://localhost:11434/v1".into()),
        }];
        s.default_api_service_ids.insert("claude".into(), "ollama-1".into());
        let json = serde_json::to_string(&s).unwrap();
        // baseURL key — explicit serde rename, mirrors macOS spelling.
        assert!(json.contains("\"baseURL\":"));
        let s2: Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(s2.api_services.len(), 1);
        assert_eq!(s2.api_services[0].id, "ollama-1");
        assert_eq!(
            s2.default_api_service_ids.get("claude"),
            Some(&"ollama-1".to_string())
        );
        assert!(s2.api_services[0].needs_separator());
    }

    #[test]
    fn needs_separator_only_when_launcher_or_model_flag_set() {
        let bare = APIService {
            id: "bare".into(),
            name: "Bare".into(),
            assistant: "claude".into(),
            launcher_prefix: None,
            model_flag: None,
            base_url: Some("http://localhost".into()),
        };
        assert!(!bare.needs_separator(), "base_url alone never needs --");
    }
}
