use crate::jsonl_parser;
use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub id: String,
    pub name: Option<String>,
    pub first_prompt: Option<String>,
    pub project_path: Option<String>,
    pub git_branch: Option<String>,
    pub message_count: usize,
    pub modified_time: DateTime<Utc>,
    pub jsonl_path: Option<String>,
}

impl Session {
    pub fn display_title(&self) -> String {
        if let Some(name) = &self.name {
            if !name.is_empty() {
                return name.clone();
            }
        }
        if let Some(prompt) = &self.first_prompt {
            if !prompt.is_empty() {
                return prompt.chars().take(100).collect();
            }
        }
        format!("{}...", &self.id[..self.id.len().min(8)])
    }
}

/// Discovers Claude Code sessions by scanning multiple directories.
pub struct SessionDiscovery {
    claude_dirs: Vec<PathBuf>,
}

impl SessionDiscovery {
    pub fn new(claude_dir: Option<PathBuf>) -> Self {
        let dirs = match claude_dir {
            Some(d) => vec![d],
            None => resolve_all_claude_dirs(),
        };
        Self { claude_dirs: dirs }
    }
}

/// Collect ALL Claude projects directories that exist on this system.
/// On Windows this includes:
///   1. %USERPROFILE%\.claude\projects  (Claude Code CLI on native Windows)
///   2. %APPDATA%\Claude\projects       (Claude Desktop app)
///   3. \\wsl$\<distro>\home\<user>\.claude\projects  (Claude Code CLI in WSL)
fn resolve_all_claude_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();

    #[cfg(target_os = "windows")]
    {
        // 1. Native Windows Claude Code CLI: %USERPROFILE%\.claude\projects
        if let Ok(profile) = std::env::var("USERPROFILE") {
            let p = PathBuf::from(&profile).join(".claude").join("projects");
            if p.exists() {
                dirs.push(p);
            }
        }

        // 2. Claude Desktop app: %APPDATA%\Claude\projects
        if let Ok(appdata) = std::env::var("APPDATA") {
            let p = PathBuf::from(&appdata).join("Claude").join("projects");
            if p.exists() {
                dirs.push(p);
            }
        }

        // 3. WSL distros via UNC paths: \\wsl$\ and \\wsl.localhost\
        for wsl_root in &["\\\\wsl$", "\\\\wsl.localhost"] {
            let root = PathBuf::from(wsl_root);
            if let Ok(distros) = std::fs::read_dir(&root) {
                for distro_entry in distros.flatten() {
                    let home_dir = distro_entry.path().join("home");
                    if let Ok(users) = std::fs::read_dir(&home_dir) {
                        for user_entry in users.flatten() {
                            let p = user_entry.path().join(".claude").join("projects");
                            if p.exists() {
                                dirs.push(p);
                            }
                        }
                    }
                    // Also check /root/.claude/projects
                    let root_p = distro_entry.path().join("root").join(".claude").join("projects");
                    if root_p.exists() {
                        dirs.push(root_p);
                    }
                }
            }
        }

        // 4. Fallback: ask wsl.exe for the home dir path directly
        //    This works even if UNC path enumeration fails.
        if let Ok(output) = std::process::Command::new("wsl.exe")
            .args(["-e", "bash", "-c", "echo $HOME"])
            .output()
        {
            let wsl_home = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !wsl_home.is_empty() {
                // Convert /home/user to \\wsl.localhost\<distro>\home\user
                // Get default distro name
                if let Ok(distro_out) = std::process::Command::new("wsl.exe")
                    .args(["-e", "bash", "-c", "cat /etc/os-release | grep ^ID= | cut -d= -f2"])
                    .output()
                {
                    let distro_id = String::from_utf8_lossy(&distro_out.stdout).trim().to_string();
                    // Try common distro names: the ID, capitalized, and well-known names
                    let candidates: Vec<String> = vec![
                        distro_id.clone(),
                        capitalize(&distro_id),
                        format!("{}-22.04", distro_id),
                        "Ubuntu".to_string(),
                        "Ubuntu-22.04".to_string(),
                        "Ubuntu-24.04".to_string(),
                        "Debian".to_string(),
                    ];
                    for wsl_root in &["\\\\wsl.localhost", "\\\\wsl$"] {
                        for name in &candidates {
                            let p = PathBuf::from(wsl_root)
                                .join(name)
                                .join(wsl_home.trim_start_matches('/'))
                                .join(".claude")
                                .join("projects");
                            if p.exists() && !dirs.contains(&p) {
                                dirs.push(p);
                            }
                        }
                    }
                }
            }
        }
    }

    #[cfg(not(target_os = "windows"))]
    {
        // WSL or Linux/macOS: check native home dir
        if let Some(home) = dirs::home_dir() {
            let p = home.join(".claude").join("projects");
            if p.exists() {
                dirs.push(p);
            }
        }

        // If inside WSL, also check the Windows-side paths
        if crate::shell_command::is_wsl() {
            if let Some(p) = wsl_claude_dir() {
                if p.exists() {
                    dirs.push(p);
                }
            }
        }
    }

    // Fallback: if nothing found, at least try the home dir
    if dirs.is_empty() {
        if let Some(home) = dirs::home_dir() {
            dirs.push(home.join(".claude").join("projects"));
        }
    }

    dirs
}

/// Find the Claude projects dir via the Windows AppData path mounted under /mnt/c.
#[cfg(not(target_os = "windows"))]
fn wsl_claude_dir() -> Option<PathBuf> {
    let users_dir = PathBuf::from("/mnt/c/Users");
    if !users_dir.exists() {
        return None;
    }
    if let Ok(profile) = std::env::var("USERPROFILE") {
        let p = PathBuf::from(profile)
            .join("AppData")
            .join("Roaming")
            .join("Claude")
            .join("projects");
        if p.exists() {
            return Some(p);
        }
    }
    let entries = std::fs::read_dir(&users_dir).ok()?;
    for entry in entries.flatten() {
        let candidate = entry
            .path()
            .join("AppData")
            .join("Roaming")
            .join("Claude")
            .join("projects");
        if candidate.exists() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(target_os = "windows")]
fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        None => String::new(),
        Some(f) => f.to_uppercase().to_string() + c.as_str(),
    }
}

impl SessionDiscovery {
    pub async fn discover_sessions(&self) -> Result<Vec<Session>> {
        let mut sessions_by_id: std::collections::HashMap<String, Session> =
            std::collections::HashMap::new();

        for claude_dir in &self.claude_dirs {
            if !claude_dir.exists() {
                continue;
            }
            self.scan_directory(claude_dir, &mut sessions_by_id).await?;
        }

        let mut sessions: Vec<Session> = sessions_by_id
            .into_values()
            .filter(|s| s.message_count > 0)
            .collect();

        // Composite step — fold in Codex + Gemini sessions. Both have
        // independently-generated ids and shouldn't collide with Claude's
        // project-encoded ksuid ids, but we dedup on id defensively so
        // a coincidence doesn't surface the same session twice.
        let mut seen_ids: std::collections::HashSet<String> =
            sessions.iter().map(|s| s.id.clone()).collect();
        for s in crate::codex_sessions::discover().await {
            if seen_ids.contains(&s.id) { continue; }
            seen_ids.insert(s.id.clone());
            sessions.push(s);
        }
        for s in crate::gemini_sessions::discover().await {
            if seen_ids.contains(&s.id) { continue; }
            seen_ids.insert(s.id.clone());
            sessions.push(s);
        }

        sessions.sort_by(|a, b| b.modified_time.cmp(&a.modified_time));
        Ok(sessions)
    }

    async fn scan_directory(
        &self,
        claude_dir: &PathBuf,
        sessions_by_id: &mut std::collections::HashMap<String, Session>,
    ) -> Result<()> {
        let mut dir_entries = tokio::fs::read_dir(claude_dir).await?;
        while let Some(entry) = dir_entries.next_entry().await? {
            let dir_path = entry.path();
            if !dir_path.is_dir() {
                continue;
            }

            let dir_name = dir_path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();

            let mut sub_entries = match tokio::fs::read_dir(&dir_path).await {
                Ok(e) => e,
                Err(_) => continue,
            };

            while let Some(file_entry) = sub_entries.next_entry().await? {
                let file_path = file_entry.path();
                let file_name = file_path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("");

                if !file_name.ends_with(".jsonl") {
                    continue;
                }

                let session_id = file_name.trim_end_matches(".jsonl").to_string();
                let file_path_str = file_path.to_string_lossy().to_string();

                let mtime = match tokio::fs::metadata(&file_path).await {
                    Ok(m) => m
                        .modified()
                        .ok()
                        .map(|t| DateTime::<Utc>::from(t))
                        .unwrap_or_else(Utc::now),
                    Err(_) => continue,
                };

                if let Ok(Some(meta)) =
                    jsonl_parser::extract_metadata(&file_path_str).await
                {
                    let entry = sessions_by_id
                        .entry(session_id.clone())
                        .or_insert_with(|| Session {
                            id: session_id.clone(),
                            name: None,
                            first_prompt: None,
                            project_path: None,
                            git_branch: None,
                            message_count: 0,
                            modified_time: mtime,
                            jsonl_path: None,
                        });

                    entry.jsonl_path = Some(file_path_str);
                    entry.modified_time = mtime;
                    entry.message_count = meta.message_count;
                    if entry.first_prompt.is_none() {
                        entry.first_prompt = meta.first_prompt;
                    }
                    if entry.project_path.is_none() {
                        entry.project_path = meta
                            .project_path
                            .or_else(|| Some(jsonl_parser::decode_directory_name(&dir_name)));
                    }
                    if entry.git_branch.is_none() {
                        entry.git_branch = meta.git_branch;
                    }
                }
            }
        }
        Ok(())
    }
}
