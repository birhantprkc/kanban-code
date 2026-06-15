//! Codex CLI session discovery — mirrors
//! `Sources/KanbanCodeCore/Adapters/Codex/CodexSessionDiscovery.swift`.
//!
//! Codex stores conversations as JSONL rollouts under
//! `~/.codex/sessions/**/rollout-*.jsonl`. Each line is a structured event
//! with a top-level `type` (`session_meta`, `response_item`, `event_msg`,
//! …) and a `payload`. The first session_meta line carries the session id,
//! cwd, and git metadata; subsequent message/function_call lines drive the
//! message count + first prompt extraction.
//!
//! A separate `~/.codex/session_index.jsonl` maps session ids to
//! user-friendly thread names. We merge that in when present so the UI
//! shows the same label Codex itself displays.
//!
//! Activity detection and transcript rendering live in follow-up sub-PRs
//! per the epic's 3-sub-PR split. This file is the discovery half only.

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::session_discovery::Session;

const FIRST_PROMPT_MAX: usize = 500;
/// Once we've seen this many conversational items and a first prompt is
/// recorded, the per-session scan returns early.
const SCAN_EARLY_EXIT_AFTER: usize = 5;

#[derive(Debug, Default)]
struct ScannedMetadata {
    session_id: Option<String>,
    project_path: Option<String>,
    git_branch: Option<String>,
    first_prompt: Option<String>,
    message_count: usize,
    saw_conversation_item: bool,
}

/// Walk `~/.codex/sessions/` (configurable for tests) and produce one
/// Session per rollout file. Files we can't parse are skipped silently —
/// the macOS reference does the same so a partially-corrupt JSONL doesn't
/// hide an otherwise-usable session list.
pub async fn discover_codex_sessions(codex_dir: Option<&Path>) -> Vec<Session> {
    let root = match codex_dir.map(PathBuf::from).or_else(default_codex_dir) {
        Some(r) => r,
        None => return Vec::new(),
    };
    if !root.exists() {
        return Vec::new();
    }

    let index = read_session_index(&root).await;
    let files = list_rollout_files(&root.join("sessions"));

    let mut sessions = Vec::new();
    for file in files {
        let Ok(meta_attrs) = std::fs::metadata(&file) else { continue };
        let modified: DateTime<Utc> = meta_attrs
            .modified()
            .ok()
            .and_then(|t| {
                t.duration_since(std::time::UNIX_EPOCH).ok().map(|d| {
                    DateTime::<Utc>::from_timestamp(d.as_secs() as i64, d.subsec_nanos()).unwrap_or_else(Utc::now)
                })
            })
            .unwrap_or_else(Utc::now);

        let Some(scanned) = scan_rollout(&file).await else { continue };
        if !scanned.saw_conversation_item {
            continue;
        }
        let session_id = scanned
            .session_id
            .unwrap_or_else(|| fallback_session_id(&file));
        if session_id.is_empty() {
            continue;
        }
        let name = index.get(&session_id).cloned();
        sessions.push(Session {
            id: session_id,
            name,
            first_prompt: scanned.first_prompt,
            project_path: scanned.project_path,
            git_branch: scanned.git_branch,
            message_count: scanned.message_count,
            modified_time: modified,
            jsonl_path: Some(file.to_string_lossy().into_owned()),
        });
    }
    sessions.sort_by(|a, b| b.modified_time.cmp(&a.modified_time));
    sessions
}

fn default_codex_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".codex"))
}

fn list_rollout_files(sessions_dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if !sessions_dir.exists() {
        return out;
    }
    for entry in walkdir::WalkDir::new(sessions_dir).into_iter().flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) != Some("jsonl") {
            continue;
        }
        out.push(p.to_path_buf());
    }
    out
}

async fn scan_rollout(path: &Path) -> Option<ScannedMetadata> {
    let bytes = tokio::fs::read(path).await.ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let mut meta = ScannedMetadata::default();

    for line in text.split('\n') {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(obj) = serde_json::from_str::<Value>(trimmed) else { continue };
        let Some(kind) = obj.get("type").and_then(|v| v.as_str()) else { continue };
        let payload = obj.get("payload");

        if kind == "session_meta" {
            if let Some(p) = payload {
                if let Some(id) = p.get("id").and_then(|v| v.as_str()) {
                    if !id.is_empty() && meta.session_id.is_none() {
                        meta.session_id = Some(id.to_string());
                    }
                }
                if meta.project_path.is_none() {
                    meta.project_path = p.get("cwd").and_then(|v| v.as_str()).map(str::to_string);
                }
                if meta.git_branch.is_none() {
                    meta.git_branch = p
                        .get("git")
                        .and_then(|g| g.get("branch"))
                        .and_then(|v| v.as_str())
                        .map(str::to_string);
                }
            }
            continue;
        }

        if kind != "response_item" {
            continue;
        }
        let Some(p) = payload else { continue };
        let item_type = p.get("type").and_then(|v| v.as_str()).unwrap_or("");
        match item_type {
            "message" => {
                let role = p.get("role").and_then(|v| v.as_str()).unwrap_or("");
                if role != "user" && role != "assistant" {
                    continue;
                }
                meta.message_count += 1;
                meta.saw_conversation_item = true;
                if role == "user" && meta.first_prompt.is_none() {
                    if let Some(text) = first_text_part(p.get("content")) {
                        let truncated: String = text.chars().take(FIRST_PROMPT_MAX).collect();
                        if !truncated.is_empty() {
                            meta.first_prompt = Some(truncated);
                        }
                    }
                }
            }
            "function_call" | "function_call_output" | "reasoning" => {
                meta.message_count += 1;
                meta.saw_conversation_item = true;
            }
            _ => continue,
        }

        if meta.message_count >= SCAN_EARLY_EXIT_AFTER && meta.first_prompt.is_some() {
            break;
        }
    }
    Some(meta)
}

/// Extracts the first non-empty text snippet from a Codex content payload.
/// Accepts both the plain-string form and the block-array form Codex uses
/// for multi-modal content.
fn first_text_part(content: Option<&Value>) -> Option<String> {
    let Some(content) = content else { return None };
    if let Some(s) = content.as_str() {
        let trimmed = s.trim();
        return if trimmed.is_empty() { None } else { Some(trimmed.to_string()) };
    }
    let Some(blocks) = content.as_array() else { return None };
    for block in blocks {
        for key in ["text", "content"] {
            if let Some(s) = block.get(key).and_then(|v| v.as_str()) {
                let trimmed = s.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            }
        }
    }
    None
}

#[derive(Debug, Deserialize)]
struct IndexEntry {
    #[serde(default)]
    id: Option<String>,
    #[serde(default, rename = "thread_name")]
    thread_name: Option<String>,
}

async fn read_session_index(root: &Path) -> HashMap<String, String> {
    let path = root.join("session_index.jsonl");
    let Ok(bytes) = tokio::fs::read(&path).await else { return HashMap::new() };
    let text = String::from_utf8_lossy(&bytes);
    let mut out = HashMap::new();
    for line in text.split('\n') {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(entry) = serde_json::from_str::<IndexEntry>(trimmed) else { continue };
        let Some(id) = entry.id else { continue };
        let Some(name) = entry.thread_name.filter(|n| !n.is_empty()) else { continue };
        out.insert(id, name);
    }
    out
}

fn fallback_session_id(path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    stem.strip_prefix("rollout-").unwrap_or(stem).to_string()
}

#[allow(dead_code)]
pub fn config_dir() -> Option<PathBuf> {
    default_codex_dir()
}

/// Public hook so callers can implement an `owns(session_path)` check
/// without re-deriving the dir path themselves.
#[allow(dead_code)]
pub fn owns_session_path(path: &str) -> bool {
    let Some(root) = default_codex_dir() else { return false };
    let normalized = path.replace('\\', "/");
    let root_str = root.to_string_lossy().replace('\\', "/");
    normalized.starts_with(&root_str)
}

pub async fn discover() -> Vec<Session> {
    discover_codex_sessions(None).await
}

#[allow(unused)]
pub use {discover_codex_sessions as discover_with_dir};

// Helpers used by tests/composite discovery; nothing here is wired to
// network or external CLIs, so they're cheap to fuzz.
#[allow(dead_code)]
pub(crate) async fn scan_for_test(path: &Path) -> Option<ScannedMetadataForTest> {
    scan_rollout(path).await.map(Into::into)
}

#[allow(dead_code)]
#[derive(Debug)]
pub(crate) struct ScannedMetadataForTest {
    pub session_id: Option<String>,
    pub project_path: Option<String>,
    pub git_branch: Option<String>,
    pub first_prompt: Option<String>,
    pub message_count: usize,
    pub saw_conversation_item: bool,
}

impl From<ScannedMetadata> for ScannedMetadataForTest {
    fn from(m: ScannedMetadata) -> Self {
        Self {
            session_id: m.session_id,
            project_path: m.project_path,
            git_branch: m.git_branch,
            first_prompt: m.first_prompt,
            message_count: m.message_count,
            saw_conversation_item: m.saw_conversation_item,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tmp_codex() -> PathBuf {
        std::env::temp_dir()
            .join(format!("kanban-codex-{}", uuid::Uuid::new_v4().simple()))
    }

    fn write_rollout(dir: &Path, name: &str, lines: &[&str]) -> PathBuf {
        fs::create_dir_all(dir).unwrap();
        let path = dir.join(name);
        fs::write(&path, lines.join("\n")).unwrap();
        path
    }

    #[tokio::test]
    async fn discovers_a_well_formed_rollout() {
        let root = tmp_codex();
        let sessions_dir = root.join("sessions").join("2026").join("06");
        write_rollout(
            &sessions_dir,
            "rollout-001.jsonl",
            &[
                r#"{"type":"session_meta","timestamp":"2026-06-15T12:00:00Z","payload":{"id":"sess-1","cwd":"C:/proj","git":{"branch":"feature/x"}}}"#,
                r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"text","text":"hello codex"}]}}"#,
                r#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
            ],
        );
        let out = discover_codex_sessions(Some(&root)).await;
        assert_eq!(out.len(), 1);
        let s = &out[0];
        assert_eq!(s.id, "sess-1");
        assert_eq!(s.project_path.as_deref(), Some("C:/proj"));
        assert_eq!(s.git_branch.as_deref(), Some("feature/x"));
        assert_eq!(s.first_prompt.as_deref(), Some("hello codex"));
        assert_eq!(s.message_count, 2);
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn falls_back_to_filename_when_session_meta_missing() {
        let root = tmp_codex();
        let sessions_dir = root.join("sessions");
        write_rollout(
            &sessions_dir,
            "rollout-abc123.jsonl",
            &[
                r#"{"type":"response_item","payload":{"type":"message","role":"user","content":"just a prompt"}}"#,
            ],
        );
        let out = discover_codex_sessions(Some(&root)).await;
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, "abc123", "should strip the rollout- prefix");
        assert_eq!(out[0].first_prompt.as_deref(), Some("just a prompt"));
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn skips_files_with_no_conversational_items() {
        let root = tmp_codex();
        let sessions_dir = root.join("sessions");
        write_rollout(
            &sessions_dir,
            "rollout-empty.jsonl",
            &[
                r#"{"type":"session_meta","payload":{"id":"empty-sess","cwd":"C:/x"}}"#,
                // No response_item rows at all.
            ],
        );
        let out = discover_codex_sessions(Some(&root)).await;
        assert!(out.is_empty(), "session_meta alone shouldn't surface a session");
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn skips_corrupt_lines_without_dropping_session() {
        let root = tmp_codex();
        let sessions_dir = root.join("sessions");
        write_rollout(
            &sessions_dir,
            "rollout-mixed.jsonl",
            &[
                r#"{"type":"session_meta","payload":{"id":"mixed","cwd":"C:/m"}}"#,
                "not valid json at all",
                r#"{"type":"response_item","payload":{"type":"message","role":"user","content":"survived"}}"#,
            ],
        );
        let out = discover_codex_sessions(Some(&root)).await;
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, "mixed");
        assert_eq!(out[0].first_prompt.as_deref(), Some("survived"));
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn session_index_supplies_thread_name() {
        let root = tmp_codex();
        let sessions_dir = root.join("sessions");
        write_rollout(
            &sessions_dir,
            "rollout-named.jsonl",
            &[
                r#"{"type":"session_meta","payload":{"id":"named-1","cwd":"C:/n"}}"#,
                r#"{"type":"response_item","payload":{"type":"message","role":"user","content":"hi"}}"#,
            ],
        );
        // Drop the index file Codex maintains.
        fs::write(
            root.join("session_index.jsonl"),
            r#"{"id":"named-1","thread_name":"Refactor mailer"}"#,
        )
        .unwrap();

        let out = discover_codex_sessions(Some(&root)).await;
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].name.as_deref(), Some("Refactor mailer"));
        let _ = fs::remove_dir_all(&root);
    }
}
