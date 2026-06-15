use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::fs;

use crate::ksuid;

// ── Queued Prompt ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueuedPrompt {
    pub id: String,
    pub body: String,
    pub send_automatically: bool,
    /// Set only for prompts the self-compact guard enqueued. Manual prompts
    /// keep this nil so we can drop stale compact nudges without touching
    /// unrelated queue items. Mirrors macOS QueuedPrompt.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub self_compact_threshold_tokens: Option<i64>,
    /// Absolute paths to images attached to this prompt. Referenced from the
    /// body via `[Image #N]` markers (1-based). Mirrors macOS QueuedPrompt.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_paths: Option<Vec<String>>,
}

// ── Sub-structs ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionLink {
    pub session_id: String,
    pub session_path: Option<String>,
    pub session_number: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeLink {
    pub path: String,
    pub branch: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrCheckRun {
    pub name: String,
    pub conclusion: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrLink {
    pub number: i64,
    pub url: Option<String>,
    pub status: Option<String>,
    pub title: Option<String>,
    pub body: Option<String>,
    pub approval_count: Option<i64>,
    pub unresolved_threads: Option<i64>,
    pub merge_state_status: Option<String>,
    /// APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED — populated from
    /// `gh pr list --json reviewDecision`. None when no review yet.
    #[serde(default)]
    pub review_decision: Option<String>,
    /// Flattened statusCheckRollup so the card UI doesn't have to fork out
    /// per-PR. Empty Vec when no CI is configured.
    #[serde(default)]
    pub check_runs: Vec<PrCheckRun>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IssueLink {
    pub number: i64,
    pub url: Option<String>,
    pub title: Option<String>,
    pub body: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ManualOverrides {
    #[serde(default)]
    pub worktree_path: bool,
    #[serde(default)]
    pub tmux_session: bool,
    #[serde(default)]
    pub name: bool,
    #[serde(default)]
    pub column: bool,
    #[serde(default)]
    pub pr_link: bool,
    #[serde(default)]
    pub issue_link: bool,
    pub dismissed_prs: Option<Vec<i64>>,
    pub branch_watermark: Option<usize>,
}

// ── Link (Card entity) ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Link {
    pub id: String,
    pub name: Option<String>,
    pub project_path: Option<String>,
    pub column: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_activity: Option<DateTime<Utc>>,
    #[serde(default)]
    pub manual_overrides: ManualOverrides,
    #[serde(default)]
    pub manually_archived: bool,
    #[serde(default = "default_source")]
    pub source: String,
    pub prompt_body: Option<String>,
    /// Images attached to `prompt_body` for unsent cards. Referenced from
    /// the body via `[Image #N]` markers (1-based). Mirrors macOS
    /// Link.promptImagePaths.
    #[serde(default)]
    pub prompt_image_paths: Option<Vec<String>>,
    pub session_link: Option<SessionLink>,
    pub worktree_link: Option<WorktreeLink>,
    #[serde(default)]
    pub pr_links: Vec<PrLink>,
    pub issue_link: Option<IssueLink>,
    pub discovered_branches: Option<Vec<String>>,
    #[serde(default = "default_false")]
    pub is_remote: bool,
    pub is_launching: Option<bool>,
    #[serde(default)]
    pub queued_prompts: Option<Vec<QueuedPrompt>>,
    /// Manual sort position within a column. `None` = fall back to time-based
    /// ordering. Set by drag-to-reorder; persisted so it survives refresh.
    #[serde(default)]
    pub sort_order: Option<f64>,
    /// When set, show this card in the pinned section while preserving its
    /// real column. The timestamp gives newest-pinned-first as a fallback
    /// when pinned_sort_order isn't set. Mirrors macOS Link.pinnedAt.
    #[serde(default)]
    pub pinned_at: Option<DateTime<Utc>>,
    /// Manual display order within the pinned section. Kept separate from
    /// sort_order so rearranging a pin never changes its column position.
    #[serde(default)]
    pub pinned_sort_order: Option<i64>,
    /// Coding assistant that owns this card. Drives which CLI binary is
    /// invoked in the embedded terminal. Defaults to "claude" so legacy
    /// links.json files (and files written by macOS without an
    /// `assistantId`) keep working.
    #[serde(default = "default_assistant")]
    pub assistant_id: String,
    /// Last time the user opened this card's drawer. Stamped by
    /// `mark_card_opened` on selectCard. Mirrors macOS Link.lastOpenedAt.
    #[serde(default)]
    pub last_opened_at: Option<DateTime<Utc>>,
    /// Per-card override for the resolved APIService (see Settings). `None`
    /// falls back to `Settings.default_api_service_ids[assistant_id]`, then
    /// to no service. Mirrors macOS Link.apiServiceId.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_service_id: Option<String>,
}

fn default_assistant() -> String {
    "claude".to_string()
}

fn default_source() -> String {
    "discovered".to_string()
}

fn default_false() -> bool {
    false
}

impl Link {
    pub fn display_title(&self) -> String {
        if let Some(name) = &self.name {
            if !name.is_empty() {
                return name.clone();
            }
        }
        if let Some(body) = &self.prompt_body {
            if !body.is_empty() {
                return body.chars().take(100).collect();
            }
        }
        if let Some(wt) = &self.worktree_link {
            if let Some(branch) = &wt.branch {
                if !branch.is_empty() {
                    return branch.clone();
                }
            }
        }
        if let Some(pr) = self.pr_links.first() {
            if let Some(title) = &pr.title {
                if !title.is_empty() {
                    return title.clone();
                }
            }
        }
        if let Some(sl) = &self.session_link {
            return sl.session_id.clone();
        }
        self.id.clone()
    }

    fn new_card(
        prompt: String,
        title: Option<String>,
        project: String,
        assistant_id: String,
        prompt_image_paths: Option<Vec<String>>,
    ) -> Self {
        let now = Utc::now();
        // KSUID matches the macOS format (chronologically sortable across the
        // links.json file). Legacy UUID-style ids still parse since `id` is
        // just a string — readers don't validate the format.
        let id = ksuid::generate(Some("card"));
        Link {
            id,
            name: title,
            project_path: Some(project),
            column: "backlog".to_string(),
            created_at: now,
            updated_at: now,
            last_activity: None,
            manual_overrides: ManualOverrides::default(),
            manually_archived: false,
            source: "manual".to_string(),
            prompt_body: Some(prompt),
            prompt_image_paths,
            session_link: None,
            worktree_link: None,
            pr_links: vec![],
            issue_link: None,
            discovered_branches: None,
            is_remote: false,
            is_launching: None,
            queued_prompts: None,
            sort_order: None,
            pinned_at: None,
            pinned_sort_order: None,
            assistant_id,
            last_opened_at: None,
            api_service_id: None,
        }
    }

    pub fn is_pinned(&self) -> bool {
        self.pinned_at.is_some()
    }
}

impl QueuedPrompt {
    pub fn new(
        body: String,
        send_automatically: bool,
        image_paths: Option<Vec<String>>,
    ) -> Self {
        Self {
            id: ksuid::generate(Some("prompt")),
            body,
            send_automatically,
            self_compact_threshold_tokens: None,
            image_paths,
        }
    }
}

// ── Container format ─────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize, Default)]
struct LinksContainer {
    links: Vec<Link>,
}

// ── Platform-aware data dir ──────────────────────────────────────────────────

/// Returns ~/.kanban-code on Linux/macOS and under WSL.
/// On native Windows uses %APPDATA%\kanban-code.
pub fn kanban_data_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        return dirs::data_dir()
            .expect("no data dir")
            .join("kanban-code");
    }
    #[cfg(not(target_os = "windows"))]
    {
        dirs::home_dir()
            .expect("no home dir")
            .join(".kanban-code")
    }
}

// ── CoordinationStore ────────────────────────────────────────────────────────

pub struct CoordinationStore {
    file_path: PathBuf,
}

impl CoordinationStore {
    pub fn new(base_path: Option<PathBuf>) -> Self {
        let base = base_path.unwrap_or_else(|| kanban_data_dir());
        Self {
            file_path: base.join("links.json"),
        }
    }

    pub async fn read_links(&self) -> Result<Vec<Link>> {
        if !self.file_path.exists() {
            return Ok(vec![]);
        }
        let data = fs::read(&self.file_path)
            .await
            .context("read links.json")?;
        // Try the normal parse first.
        if let Ok(container) = serde_json::from_slice::<LinksContainer>(&data) {
            return Ok(container.links);
        }
        // Corruption recovery: copy the bad file to links.json.bkp and start
        // fresh, mirroring macOS CoordinationStore.swift (~L105). Losing all
        // cards is bad, but at least the user can inspect the .bkp afterwards
        // — silently returning empty without a backup is worse.
        let backup_path = self.file_path.with_extension("json.bkp");
        if let Err(e) = fs::copy(&self.file_path, &backup_path).await {
            crate::logging::error(
                "coordination",
                &format!("failed to back up corrupt links.json to {:?}: {e}", backup_path),
            );
        } else {
            crate::logging::warn(
                "coordination",
                &format!(
                    "links.json failed to parse; copied to {:?} and resetting to empty",
                    backup_path
                ),
            );
        }
        Ok(vec![])
    }

    pub async fn write_links(&self, links: &[Link]) -> Result<()> {
        if let Some(parent) = self.file_path.parent() {
            fs::create_dir_all(parent).await.context("create .kanban-code dir")?;
        }
        let container = LinksContainer {
            links: links.to_vec(),
        };
        let data = serde_json::to_vec_pretty(&container).context("serialize links")?;
        let tmp = self.file_path.with_extension("json.tmp");
        fs::write(&tmp, &data).await.context("write tmp")?;
        fs::rename(&tmp, &self.file_path).await.context("rename tmp")?;
        Ok(())
    }

    pub async fn upsert_link(&self, link: &Link) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(idx) = links.iter().position(|l| l.id == link.id) {
            links[idx] = link.clone();
        } else {
            links.push(link.clone());
        }
        self.write_links(&links).await
    }

    pub async fn move_card(&self, card_id: &str, column: &str) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            link.column = column.to_string();
            link.manual_overrides.column = true;
            if column == "all_sessions" {
                link.manually_archived = true;
                link.pinned_at = None;
                link.pinned_sort_order = None;
            } else if link.manually_archived {
                link.manually_archived = false;
            }
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await
    }

    pub async fn create_card(
        &self,
        prompt: String,
        title: Option<String>,
        project: String,
        assistant_id: String,
        prompt_image_paths: Option<Vec<String>>,
        api_service_id: Option<String>,
    ) -> Result<Link> {
        let mut link = Link::new_card(prompt, title, project, assistant_id, prompt_image_paths);
        link.api_service_id = api_service_id;
        self.upsert_link(&link).await?;
        Ok(link)
    }

    /// Set or clear the per-card APIService override. Passing `None` clears
    /// the override (card falls back to the per-assistant default).
    pub async fn set_card_api_service(
        &self,
        card_id: &str,
        api_service_id: Option<String>,
    ) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            link.api_service_id = api_service_id;
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await
    }

    pub async fn remove_link(&self, card_id: &str) -> Result<()> {
        let mut links = self.read_links().await?;
        links.retain(|l| l.id != card_id);
        self.write_links(&links).await
    }

    pub async fn archive_link(&self, card_id: &str) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            link.manually_archived = true;
            link.column = "all_sessions".to_string();
            link.pinned_at = None;
            link.pinned_sort_order = None;
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await
    }

    pub async fn rename_link(&self, card_id: &str, name: &str) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            link.name = Some(name.to_string());
            link.manual_overrides.name = true;
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await
    }

    pub async fn add_queued_prompt(
        &self,
        card_id: &str,
        prompt: QueuedPrompt,
    ) -> Result<QueuedPrompt> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            let prompts = link.queued_prompts.get_or_insert_with(Vec::new);
            prompts.push(prompt.clone());
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await?;
        Ok(prompt)
    }

    pub async fn update_queued_prompt(
        &self,
        card_id: &str,
        prompt_id: &str,
        body: &str,
        send_automatically: bool,
        image_paths: Option<Option<Vec<String>>>,
    ) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            if let Some(prompts) = &mut link.queued_prompts {
                if let Some(p) = prompts.iter_mut().find(|p| p.id == prompt_id) {
                    p.body = body.to_string();
                    p.send_automatically = send_automatically;
                    // Three states for image_paths:
                    //   None         — caller didn't pass; keep what's there
                    //   Some(None)   — caller wants to clear the attachments
                    //   Some(Some(v))— caller wants to replace with `v`
                    if let Some(new_paths) = image_paths {
                        p.image_paths = new_paths;
                    }
                }
            }
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await
    }

    /// Create a card from a GitHub issue, returning the new Link.
    pub async fn create_issue_card(
        &self,
        project_path: &str,
        issue_number: i64,
        issue_title: &str,
        issue_url: &str,
        issue_body: Option<&str>,
        prompt_body: &str,
    ) -> Result<Link> {
        let now = Utc::now();
        let id = ksuid::generate(Some("card"));
        let link = Link {
            id,
            name: Some(format!("#{}: {}", issue_number, issue_title)),
            project_path: Some(project_path.to_string()),
            column: "backlog".to_string(),
            created_at: now,
            updated_at: now,
            last_activity: None,
            manual_overrides: ManualOverrides::default(),
            manually_archived: false,
            source: "github_issue".to_string(),
            prompt_body: Some(prompt_body.to_string()),
            prompt_image_paths: None,
            session_link: None,
            worktree_link: None,
            pr_links: vec![],
            issue_link: Some(IssueLink {
                number: issue_number,
                url: Some(issue_url.to_string()),
                title: Some(issue_title.to_string()),
                body: issue_body.map(|s| s.to_string()),
            }),
            discovered_branches: None,
            is_remote: false,
            is_launching: None,
            queued_prompts: None,
            sort_order: None,
            pinned_at: None,
            pinned_sort_order: None,
            assistant_id: default_assistant(),
            last_opened_at: None,
            api_service_id: None,
        };
        self.upsert_link(&link).await?;
        Ok(link)
    }

    pub async fn remove_queued_prompt(&self, card_id: &str, prompt_id: &str) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            if let Some(prompts) = &mut link.queued_prompts {
                prompts.retain(|p| p.id != prompt_id);
                if prompts.is_empty() {
                    link.queued_prompts = None;
                }
            }
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await
    }

    /// Persist a manual ordering by assigning each card its index in
    /// `ordered_ids` as `sort_order`. Intentionally does NOT bump `updated_at`,
    /// so reordering never reshuffles time-based sorting elsewhere.
    pub async fn reorder_cards(&self, ordered_ids: &[String]) -> Result<()> {
        let mut links = self.read_links().await?;
        for (idx, id) in ordered_ids.iter().enumerate() {
            if let Some(link) = links.iter_mut().find(|l| &l.id == id) {
                link.sort_order = Some(idx as f64);
            }
        }
        self.write_links(&links).await
    }

    /// Pin or unpin a card. Pinning stamps `pinned_at = now` and assigns a
    /// pinned_sort_order one slot above the current first-pinned (so the
    /// new pin lands at the top, matching macOS). Unpinning clears both
    /// fields. No-op when the requested state already matches.
    pub async fn set_card_pinned(&self, card_id: &str, is_pinned: bool) -> Result<()> {
        let mut links = self.read_links().await?;
        let first_order = links
            .iter()
            .filter_map(|l| l.pinned_sort_order)
            .min()
            .unwrap_or(0);
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            if is_pinned {
                if link.pinned_at.is_some() {
                    return Ok(());
                }
                link.pinned_at = Some(Utc::now());
                link.pinned_sort_order = Some(first_order - 1);
            } else {
                if link.pinned_at.is_none() {
                    return Ok(());
                }
                link.pinned_at = None;
                link.pinned_sort_order = None;
            }
            link.updated_at = Utc::now();
        }
        self.write_links(&links).await
    }

    /// Stamp `last_opened_at = now` on the named card. Mirrors macOS
    /// `selectCard` side effect. Intentionally does NOT bump `updated_at` so
    /// merely opening a card doesn't push it to the top of time-based sorts.
    pub async fn mark_card_opened(&self, card_id: &str) -> Result<()> {
        let mut links = self.read_links().await?;
        if let Some(link) = links.iter_mut().find(|l| l.id == card_id) {
            link.last_opened_at = Some(Utc::now());
        }
        self.write_links(&links).await
    }

    /// Persist a manual ordering of pinned cards by assigning each its index
    /// in `ordered_ids` as `pinned_sort_order`. Like reorder_cards, this does
    /// NOT bump `updated_at` so the sort doesn't ripple into time-based
    /// presentations elsewhere.
    pub async fn reorder_pinned_cards(&self, ordered_ids: &[String]) -> Result<()> {
        let mut links = self.read_links().await?;
        for (idx, id) in ordered_ids.iter().enumerate() {
            if let Some(link) = links.iter_mut().find(|l| &l.id == id) {
                if link.pinned_at.is_some() {
                    link.pinned_sort_order = Some(idx as i64);
                }
            }
        }
        self.write_links(&links).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_base() -> PathBuf {
        std::env::temp_dir()
            .join(format!("kanban-coord-{}", uuid::Uuid::new_v4().simple()))
    }

    #[tokio::test]
    async fn mark_card_opened_stamps_last_opened_at_without_bumping_updated() {
        let base = tmp_base();
        let store = CoordinationStore::new(Some(base.clone()));
        let created = store
            .create_card(
                "prompt".into(),
                Some("title".into()),
                "C:/proj".into(),
                "claude".into(),
                None,
            )
            .await
            .unwrap();
        // Snapshot updated_at before marking opened.
        let before_updated = created.updated_at;
        assert!(created.last_opened_at.is_none());

        store.mark_card_opened(&created.id).await.unwrap();

        let after = store.read_links().await.unwrap();
        let link = after.iter().find(|l| l.id == created.id).unwrap();
        assert!(
            link.last_opened_at.is_some(),
            "mark_card_opened should stamp last_opened_at"
        );
        assert_eq!(
            link.updated_at, before_updated,
            "mark_card_opened must not bump updated_at — sorting by activity would jitter on plain opens"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn mark_card_opened_unknown_id_is_noop() {
        let base = tmp_base();
        let store = CoordinationStore::new(Some(base.clone()));
        // No cards exist yet; mark_card_opened on a bogus id should not error.
        store.mark_card_opened("card_does_not_exist").await.unwrap();
        assert!(store.read_links().await.unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&base);
    }
}
