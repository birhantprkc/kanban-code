//! Gemini CLI session discovery — mirrors
//! `Sources/KanbanCodeCore/Adapters/Gemini/GeminiSessionDiscovery.swift`.
//!
//! On-disk layout:
//!   ~/.gemini/projects.json                 — { "projects": { "<abs_path>": "<slug>" } }
//!   ~/.gemini/tmp/<slug>/chats/session-*.json — single-file JSON sessions
//!
//! Each session file is a single JSON object with a `messages` array and a
//! `sessionId`. Conversational messages are `type: "user"` or
//! `type: "gemini"`; `info` / `error` messages are skipped for the
//! message-count derivation (matches macOS).
//!
//! This file is the discovery half only — activity detection and full
//! transcript rendering land in #124 sub-PR 3/3.

use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::session_discovery::Session;

const FIRST_PROMPT_MAX: usize = 500;

#[derive(Debug, Deserialize)]
struct SessionFile {
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    #[serde(default)]
    summary: Option<String>,
    #[serde(default)]
    messages: Vec<Value>,
}

#[derive(Debug, Deserialize)]
struct ProjectsFile {
    #[serde(default)]
    projects: HashMap<String, String>, // abs_path → slug
}

pub async fn discover_gemini_sessions(gemini_dir: Option<&Path>) -> Vec<Session> {
    let root = match gemini_dir.map(PathBuf::from).or_else(default_gemini_dir) {
        Some(r) => r,
        None => return Vec::new(),
    };
    if !root.exists() {
        return Vec::new();
    }
    let slug_to_path = read_projects_mapping(&root).await;
    let tmp = root.join("tmp");
    if !tmp.exists() {
        return Vec::new();
    }

    let mut sessions = Vec::new();
    let Ok(mut slugs) = tokio::fs::read_dir(&tmp).await else { return sessions };
    while let Ok(Some(slug_entry)) = slugs.next_entry().await {
        let slug_path = slug_entry.path();
        let Some(slug_name) = slug_path.file_name().and_then(|s| s.to_str()).map(str::to_string)
        else { continue };
        let chats_dir = slug_path.join("chats");
        if !chats_dir.is_dir() {
            continue;
        }
        let project_path = slug_to_path.get(&slug_name).cloned();

        let Ok(mut files) = tokio::fs::read_dir(&chats_dir).await else { continue };
        while let Ok(Some(entry)) = files.next_entry().await {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|s| s.to_str()) else { continue };
            if !name.starts_with("session-") || !name.ends_with(".json") {
                continue;
            }
            let modified = file_modified(&path).await.unwrap_or_else(Utc::now);
            let Some(session) = read_session(&path, &project_path, modified).await else { continue };
            sessions.push(session);
        }
    }
    sessions.sort_by(|a, b| b.modified_time.cmp(&a.modified_time));
    sessions
}

fn default_gemini_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".gemini"))
}

async fn file_modified(path: &Path) -> Option<DateTime<Utc>> {
    let meta = tokio::fs::metadata(path).await.ok()?;
    let modified = meta.modified().ok()?;
    let dur = modified.duration_since(std::time::UNIX_EPOCH).ok()?;
    DateTime::<Utc>::from_timestamp(dur.as_secs() as i64, dur.subsec_nanos())
}

async fn read_projects_mapping(root: &Path) -> HashMap<String, String> {
    let path = root.join("projects.json");
    let Ok(bytes) = tokio::fs::read(&path).await else { return HashMap::new() };
    let Ok(file) = serde_json::from_slice::<ProjectsFile>(&bytes) else { return HashMap::new() };
    // Invert path→slug into slug→path so callers can look up by slug.
    let mut out = HashMap::with_capacity(file.projects.len());
    for (abs_path, slug) in file.projects {
        out.insert(slug, abs_path);
    }
    out
}

async fn read_session(
    path: &Path,
    project_path: &Option<String>,
    modified: DateTime<Utc>,
) -> Option<Session> {
    let bytes = tokio::fs::read(path).await.ok()?;
    let file: SessionFile = serde_json::from_slice(&bytes).ok()?;
    let session_id = file.session_id?;
    if session_id.is_empty() {
        return None;
    }

    let conv_count = file
        .messages
        .iter()
        .filter(|m| {
            m.get("type")
                .and_then(|t| t.as_str())
                .is_some_and(|t| t == "user" || t == "gemini")
        })
        .count();
    if conv_count == 0 {
        // Mirrors macOS: an info/error-only session is not surfaced.
        return None;
    }

    let first_prompt = file
        .messages
        .iter()
        .find(|m| m.get("type").and_then(|t| t.as_str()) == Some("user"))
        .and_then(|m| first_text_from(m.get("content")))
        .map(|s| s.chars().take(FIRST_PROMPT_MAX).collect::<String>())
        .filter(|s| !s.is_empty());

    Some(Session {
        id: session_id,
        name: file.summary.filter(|s| !s.is_empty()),
        first_prompt,
        project_path: project_path.clone(),
        git_branch: None,
        message_count: conv_count,
        modified_time: modified,
        jsonl_path: Some(path.to_string_lossy().into_owned()),
    })
}

/// Gemini content is either a bare string (gemini/info/error messages) or
/// an array of `{ "text": "..." }` parts (user messages). Pull the first
/// non-empty text out either way.
fn first_text_from(content: Option<&Value>) -> Option<String> {
    let content = content?;
    if let Some(s) = content.as_str() {
        let trimmed = s.trim();
        return if trimmed.is_empty() { None } else { Some(trimmed.to_string()) };
    }
    let arr = content.as_array()?;
    for block in arr {
        if let Some(s) = block.get("text").and_then(|v| v.as_str()) {
            let trimmed = s.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

pub async fn discover() -> Vec<Session> {
    discover_gemini_sessions(None).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tmp_gemini() -> PathBuf {
        std::env::temp_dir()
            .join(format!("kanban-gemini-{}", uuid::Uuid::new_v4().simple()))
    }

    fn write_session(dir: &Path, name: &str, body: &str) -> PathBuf {
        fs::create_dir_all(dir).unwrap();
        let path = dir.join(name);
        fs::write(&path, body).unwrap();
        path
    }

    #[tokio::test]
    async fn discovers_a_well_formed_session() {
        let root = tmp_gemini();
        let chats = root.join("tmp").join("abc-slug").join("chats");
        write_session(
            &chats,
            "session-2026-06-15.json",
            r#"{
                "sessionId": "gem-1",
                "summary": "Refactor mailer",
                "messages": [
                    { "type": "user", "content": [{ "text": "hello gemini" }] },
                    { "type": "gemini", "content": "hi back" },
                    { "type": "info", "content": "system note" }
                ]
            }"#,
        );
        // Map the slug back to a real project path.
        fs::write(
            root.join("projects.json"),
            r#"{ "projects": { "C:/proj": "abc-slug" } }"#,
        )
        .unwrap();
        let out = discover_gemini_sessions(Some(&root)).await;
        assert_eq!(out.len(), 1);
        let s = &out[0];
        assert_eq!(s.id, "gem-1");
        assert_eq!(s.name.as_deref(), Some("Refactor mailer"));
        assert_eq!(s.project_path.as_deref(), Some("C:/proj"));
        assert_eq!(s.first_prompt.as_deref(), Some("hello gemini"));
        // Info/error messages are excluded from the count by design.
        assert_eq!(s.message_count, 2);
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn skips_sessions_with_no_user_or_gemini_messages() {
        let root = tmp_gemini();
        let chats = root.join("tmp").join("info-only").join("chats");
        write_session(
            &chats,
            "session-x.json",
            r#"{
                "sessionId": "noop",
                "messages": [
                    { "type": "info", "content": "started" },
                    { "type": "error", "content": "bad request" }
                ]
            }"#,
        );
        let out = discover_gemini_sessions(Some(&root)).await;
        assert!(out.is_empty(), "non-conversational sessions must be dropped");
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn projects_json_missing_yields_no_project_path() {
        let root = tmp_gemini();
        let chats = root.join("tmp").join("unmapped").join("chats");
        write_session(
            &chats,
            "session-y.json",
            r#"{
                "sessionId": "no-proj",
                "messages": [{ "type": "user", "content": "hey" }]
            }"#,
        );
        // No projects.json at all.
        let out = discover_gemini_sessions(Some(&root)).await;
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, "no-proj");
        assert!(out[0].project_path.is_none(), "unmapped slug → None project path");
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn ignores_files_outside_session_glob() {
        let root = tmp_gemini();
        let chats = root.join("tmp").join("noise").join("chats");
        fs::create_dir_all(&chats).unwrap();
        // Non-session files should be left alone.
        fs::write(chats.join("README.txt"), "hi").unwrap();
        fs::write(
            chats.join("session-real.json"),
            r#"{ "sessionId": "real", "messages": [{ "type": "user", "content": "a" }] }"#,
        )
        .unwrap();
        let out = discover_gemini_sessions(Some(&root)).await;
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, "real");
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn corrupt_session_file_is_skipped() {
        let root = tmp_gemini();
        let chats = root.join("tmp").join("mixed").join("chats");
        fs::create_dir_all(&chats).unwrap();
        fs::write(chats.join("session-broken.json"), "{ not json").unwrap();
        write_session(
            &chats,
            "session-ok.json",
            r#"{ "sessionId": "ok", "messages": [{ "type": "user", "content": "ok" }] }"#,
        );
        let out = discover_gemini_sessions(Some(&root)).await;
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, "ok");
        let _ = fs::remove_dir_all(&root);
    }
}
