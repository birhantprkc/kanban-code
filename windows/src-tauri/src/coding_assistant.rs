//! Multi-assistant abstraction. Mirrors the shape of macOS
//! `Sources/KanbanCodeCore/Domain/Entities/CodingAssistant.swift` so a
//! `links.json` carrying `assistantId` moves between platforms cleanly.
//!
//! This is the minimum-viable port: it covers the launch/resume command
//! shape so the embedded terminal can swap between Claude and Gemini, and
//! provides a `~/.gemini` discovery scaffolding for future use. Activity
//! detection and hooks remain Claude-only for now — see TODO in
//! `discover_gemini_sessions`.
//!
//! Adding a new assistant: extend `AssistantId`, fill in the per-arm
//! matches below, and (optionally) wire up discovery.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Hash)]
#[serde(rename_all = "lowercase")]
pub enum AssistantId {
    Claude,
    Codex,
    Gemini,
}

impl Default for AssistantId {
    fn default() -> Self {
        AssistantId::Claude
    }
}

impl AssistantId {
    pub fn all() -> &'static [AssistantId] {
        &[AssistantId::Claude, AssistantId::Codex, AssistantId::Gemini]
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            AssistantId::Claude => "claude",
            AssistantId::Codex => "codex",
            AssistantId::Gemini => "gemini",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "claude" => Some(AssistantId::Claude),
            "codex" => Some(AssistantId::Codex),
            "gemini" => Some(AssistantId::Gemini),
            _ => None,
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            AssistantId::Claude => "Claude Code",
            AssistantId::Codex => "Codex CLI",
            AssistantId::Gemini => "Gemini CLI",
        }
    }

    /// Binary name on PATH. We don't take an absolute path — assume the
    /// user has the CLI installed via `npm install -g`, matching macOS
    /// behavior. Configurable paths are a follow-up.
    pub fn cli_command(&self) -> &'static str {
        match self {
            AssistantId::Claude => "claude",
            AssistantId::Codex => "codex",
            AssistantId::Gemini => "gemini",
        }
    }

    /// CLI flag for auto-approving all tool calls.
    pub fn auto_approve_flag(&self) -> &'static str {
        match self {
            AssistantId::Claude => "--dangerously-skip-permissions",
            // Codex's auto-approve is `--full-auto`. Mirrors macOS
            // `CodingAssistant.codex.autoApproveFlag`.
            AssistantId::Codex => "--full-auto",
            AssistantId::Gemini => "--yolo",
        }
    }

    /// Resume an existing session id.
    pub fn resume_flag(&self) -> &'static str {
        match self {
            // Codex uses `--resume <id>` like the others; the `codex resume`
            // subcommand exists too but the flag form composes with --full-auto.
            AssistantId::Claude | AssistantId::Codex | AssistantId::Gemini => "--resume",
        }
    }

    /// Config dir under $HOME (e.g. ".claude", ".codex", ".gemini"). Used by
    /// discovery and by the macOS `owns(sessionPath:)` check.
    pub fn config_dir_name(&self) -> &'static str {
        match self {
            AssistantId::Claude => ".claude",
            AssistantId::Codex => ".codex",
            AssistantId::Gemini => ".gemini",
        }
    }
}

/// Thin compatibility shim. Real discovery lives in `gemini_sessions`,
/// where it's also fold into the composite SessionDiscovery output. This
/// function is kept so existing callers (and future #124 sub-PR 3 wiring)
/// have a single entry point that's stable across reorgs.
pub async fn discover_gemini_sessions() -> Vec<crate::session_discovery::Session> {
    crate::gemini_sessions::discover().await
}

#[allow(dead_code)]
fn gemini_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".gemini"))
}
