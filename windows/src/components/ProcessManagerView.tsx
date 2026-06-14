import { invoke } from "@tauri-apps/api/core";
import { useEffect, useState } from "react";
import { ask } from "@tauri-apps/plugin-dialog";
import { removeWorktree, useBoardStore } from "../store/boardStore";
import { useTheme, t } from "../theme";

interface TmuxSessionInfo {
  name: string;
  createdAt: number;
  attached: boolean;
  windows: number;
}

interface ClaudeProcessInfo {
  pid: number;
  command: string;
  sessionId?: string;
}

interface WorktreeRow {
  repoRoot: string;
  projectName: string;
  path: string;
  branch?: string;
  isMain: boolean;
}

interface ProcessState {
  tmuxSessions: TmuxSessionInfo[];
  claudeProcesses: ClaudeProcessInfo[];
  worktrees: WorktreeRow[];
}

type Tab = "tmux" | "claude" | "worktrees";

interface Props {
  open: boolean;
  onClose: () => void;
}

export default function ProcessManagerView({ open, onClose }: Props) {
  const { theme } = useTheme();
  const c = t(theme);
  const cards = useBoardStore((s) => s.cards);
  const selectCard = useBoardStore((s) => s.selectCard);

  const [tab, setTab] = useState<Tab>("tmux");
  const [state, setState] = useState<ProcessState>({
    tmuxSessions: [],
    claudeProcesses: [],
    worktrees: [],
  });
  const [loading, setLoading] = useState(false);
  const [removingPaths, setRemovingPaths] = useState<Set<string>>(new Set());

  const refresh = async () => {
    setLoading(true);
    try {
      const s = await invoke<ProcessState>("get_process_state");
      setState(s);
    } catch (e) {
      useBoardStore.setState({ error: String(e) });
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (open) refresh();
  }, [open]);

  if (!open) return null;

  // Link a tmux session name to a card when the user owns the session — same
  // identity rule as macOS: cards stash their tmux session id (a ksuid) and
  // the session name matches that exactly.
  const cardForTmuxSession = (sessionName: string) =>
    cards.find((card) => sessionName === card.id || sessionName.endsWith(card.id));

  // Link a Claude process to a card via session id.
  const cardForClaudeProcess = (proc: ClaudeProcessInfo) =>
    proc.sessionId
      ? cards.find((card) => card.link.sessionLink?.sessionId === proc.sessionId)
      : undefined;

  const killTmux = async (name: string) => {
    try {
      await invoke("tmux_kill_session", { name });
      await refresh();
    } catch (e) {
      useBoardStore.setState({ error: String(e) });
    }
  };

  const killClaude = async (pid: number) => {
    const ok = await ask(`Kill Claude process ${pid}?`, {
      title: "Kill process",
      kind: "warning",
      okLabel: "Kill",
      cancelLabel: "Cancel",
    });
    if (!ok) return;
    try {
      await invoke("kill_claude_process", { pid });
      await refresh();
    } catch (e) {
      useBoardStore.setState({ error: String(e) });
    }
  };

  const removeWt = async (row: WorktreeRow) => {
    if (row.isMain) return;
    const ok = await ask(
      `Remove worktree at ${row.path}?\n\nThe directory is deleted; the branch stays.`,
      { title: "Remove worktree", kind: "warning", okLabel: "Remove", cancelLabel: "Cancel" }
    );
    if (!ok) return;
    setRemovingPaths((prev) => new Set(prev).add(row.path));
    try {
      await removeWorktree(row.path, row.repoRoot, false);
      await refresh();
    } catch (e) {
      useBoardStore.setState({ error: String(e) });
    } finally {
      setRemovingPaths((prev) => {
        const next = new Set(prev);
        next.delete(row.path);
        return next;
      });
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      style={{ background: c.bgOverlay }}
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div
        className="rounded-2xl shadow-2xl flex flex-col animate-slide-up"
        style={{
          width: 720,
          height: 540,
          background: c.bgDialog,
          border: `1px solid ${c.border}`,
        }}
        onKeyDown={(e) => { if (e.key === "Escape") onClose(); }}
      >
        {/* Header */}
        <div className="px-6 pt-5 pb-3 flex items-center justify-between">
          <h2 className="text-[16px] font-semibold" style={{ color: c.textPrimary }}>
            Process Manager
          </h2>
          <button
            onClick={onClose}
            className="transition-colors"
            style={{ color: c.textMuted }}
            onMouseEnter={(e) => { e.currentTarget.style.color = c.textPrimary; }}
            onMouseLeave={(e) => { e.currentTarget.style.color = c.textMuted; }}
            aria-label="Close"
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Tabs */}
        <div className="px-6 pb-3 flex items-center gap-1">
          {(["tmux", "claude", "worktrees"] as Tab[]).map((id) => (
            <button
              key={id}
              onClick={() => setTab(id)}
              className="px-3 py-1.5 rounded-lg text-[13px] font-medium transition-colors"
              style={{
                background: tab === id ? c.bgInput : "transparent",
                color: tab === id ? c.textPrimary : c.textMuted,
                border: `1px solid ${tab === id ? c.borderBright : "transparent"}`,
              }}
            >
              {id === "tmux"
                ? `Tmux (${state.tmuxSessions.length})`
                : id === "claude"
                ? `Claude (${state.claudeProcesses.length})`
                : `Worktrees (${state.worktrees.length})`}
            </button>
          ))}
          <span className="flex-1" />
          <button
            onClick={refresh}
            disabled={loading}
            className="px-3 py-1.5 rounded-lg text-[13px] transition-colors disabled:opacity-50"
            style={{ color: c.textSecondary, border: `1px solid ${c.border}` }}
            onMouseEnter={(e) => { if (!loading) e.currentTarget.style.background = c.hoverBg; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
            title="Refresh"
          >
            {loading ? "Refreshing…" : "Refresh"}
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto px-6 pb-4">
          {tab === "tmux" && (
            <TableEmpty when={state.tmuxSessions.length === 0} c={c} message="No active tmux sessions. Requires WSL + tmux installed." />
          )}
          {tab === "tmux" && state.tmuxSessions.map((s) => {
            const card = cardForTmuxSession(s.name);
            return (
              <Row key={s.name} c={c}>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-[13px] truncate" style={{ color: c.textPrimary }}>{s.name}</span>
                    {s.attached && (
                      <span className="text-[10px] px-1.5 py-0.5 rounded uppercase tracking-wider" style={{ background: "#3fb95018", color: "#3fb950" }}>
                        attached
                      </span>
                    )}
                  </div>
                  <div className="text-[11px] mt-0.5" style={{ color: c.textDim }}>
                    {s.windows} window{s.windows === 1 ? "" : "s"} · created {fmtAgo(s.createdAt * 1000)}
                    {card && <> · <CardLink card={card} onSelect={() => { selectCard(card.id); onClose(); }} c={c} /></>}
                  </div>
                </div>
                <RowAction onClick={() => killTmux(s.name)} c={c} label="Kill" danger />
              </Row>
            );
          })}

          {tab === "claude" && (
            <TableEmpty when={state.claudeProcesses.length === 0} c={c} message="No Claude processes running." />
          )}
          {tab === "claude" && state.claudeProcesses.map((p) => {
            const card = cardForClaudeProcess(p);
            return (
              <Row key={p.pid} c={c}>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-[13px]" style={{ color: c.textPrimary }}>PID {p.pid}</span>
                    {p.sessionId && (
                      <span className="text-[10px] px-1.5 py-0.5 rounded font-mono" style={{ background: c.bgInput, color: c.textMuted }}>
                        {p.sessionId.slice(0, 8)}
                      </span>
                    )}
                  </div>
                  <div className="text-[11px] mt-0.5 font-mono truncate" style={{ color: c.textDim }} title={p.command}>
                    {p.command}
                  </div>
                  {card && (
                    <div className="text-[11px] mt-0.5" style={{ color: c.textDim }}>
                      <CardLink card={card} onSelect={() => { selectCard(card.id); onClose(); }} c={c} />
                    </div>
                  )}
                </div>
                <RowAction onClick={() => killClaude(p.pid)} c={c} label="Kill" danger />
              </Row>
            );
          })}

          {tab === "worktrees" && (
            <TableEmpty when={state.worktrees.length === 0} c={c} message="No worktrees found. Configure a project in Settings → Projects." />
          )}
          {tab === "worktrees" && state.worktrees.map((row) => (
            <Row key={`${row.repoRoot}::${row.path}`} c={c}>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <span className="text-[13px] truncate" style={{ color: c.textPrimary }}>{row.projectName}</span>
                  {row.branch && (
                    <span className="text-[11px] px-1.5 py-0.5 rounded" style={{ background: "#4f8ef718", color: "#4f8ef7" }}>
                      {row.branch}
                    </span>
                  )}
                  {row.isMain && (
                    <span className="text-[10px] px-1.5 py-0.5 rounded uppercase tracking-wider" style={{ background: c.bgInput, color: c.textMuted }}>
                      main
                    </span>
                  )}
                </div>
                <div className="text-[11px] mt-0.5 font-mono truncate" style={{ color: c.textDim }} title={row.path}>
                  {row.path}
                </div>
              </div>
              {!row.isMain && (
                <RowAction
                  onClick={() => removeWt(row)}
                  c={c}
                  label={removingPaths.has(row.path) ? "Removing…" : "Remove"}
                  danger
                  disabled={removingPaths.has(row.path)}
                />
              )}
            </Row>
          ))}
        </div>
      </div>
    </div>
  );
}

function Row({ children, c }: { children: React.ReactNode; c: ReturnType<typeof t> }) {
  return (
    <div
      className="flex items-center gap-3 px-3 py-2.5 rounded-lg mb-1.5"
      style={{ border: `1px solid ${c.border}`, background: c.bgCard }}
    >
      {children}
    </div>
  );
}

function RowAction({
  onClick, c, label, danger, disabled,
}: {
  onClick: () => void;
  c: ReturnType<typeof t>;
  label: string;
  danger?: boolean;
  disabled?: boolean;
}) {
  const color = danger ? "#f85149" : c.textSecondary;
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className="px-3 py-1.5 rounded text-[12px] font-medium transition-colors shrink-0 disabled:opacity-50"
      style={{ color, border: `1px solid ${color}40` }}
      onMouseEnter={(e) => { if (!disabled) e.currentTarget.style.background = color + "12"; }}
      onMouseLeave={(e) => { e.currentTarget.style.background = "transparent"; }}
    >
      {label}
    </button>
  );
}

function CardLink({
  card,
  onSelect,
  c,
}: {
  card: { id: string; displayTitle: string };
  onSelect: () => void;
  c: ReturnType<typeof t>;
}) {
  return (
    <button
      onClick={onSelect}
      className="underline-offset-2 hover:underline transition-colors"
      style={{ color: c.textSecondary }}
      title="Open this card"
    >
      → {card.displayTitle}
    </button>
  );
}

function TableEmpty({ when, c, message }: { when: boolean; c: ReturnType<typeof t>; message: string }) {
  if (!when) return null;
  return (
    <div
      className="flex items-center justify-center py-12 rounded-lg text-[12px]"
      style={{ color: c.textDim, border: `1px dashed ${c.border}` }}
    >
      {message}
    </div>
  );
}

function fmtAgo(ms: number): string {
  const dt = Date.now() - ms;
  const sec = Math.floor(dt / 1000);
  if (sec < 60) return `${sec}s ago`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  return `${Math.floor(hr / 24)}d ago`;
}
