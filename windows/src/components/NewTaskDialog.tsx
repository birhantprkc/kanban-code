import { useEffect, useRef, useState } from "react";
import { getSettings, saveClipboardImage, useBoardStore } from "../store/boardStore";
import { useTheme, t } from "../theme";
import { ASSISTANT_DISPLAY, type APIService, type AssistantId } from "../types";
import { imageMarker, removeImageAtIndex } from "../lib/promptImageLayout";

export default function NewTaskDialog() {
  const { createCard, setNewTaskOpen, selectCard, cards } = useBoardStore();
  const { theme } = useTheme();
  const c = t(theme);
  const [prompt, setPrompt] = useState("");
  const [title, setTitle] = useState("");
  const [project, setProject] = useState("");
  const [launch, setLaunch] = useState(true);
  const [assistantId, setAssistantId] = useState<AssistantId>("claude");
  const [submitting, setSubmitting] = useState(false);
  const [settingsProjects, setSettingsProjects] = useState<string[]>([]);
  const [imagePaths, setImagePaths] = useState<string[]>([]);
  const [apiServices, setApiServices] = useState<APIService[]>([]);
  const [defaultAPIServiceIds, setDefaultAPIServiceIds] = useState<Record<string, string>>({});
  // null = "use the per-assistant default"; a service id pins this card's
  // override regardless of the default.
  const [apiServiceId, setApiServiceId] = useState<string | null>(null);
  const promptRef = useRef<HTMLTextAreaElement>(null);

  const handlePromptPaste = async (e: React.ClipboardEvent<HTMLTextAreaElement>) => {
    const items = Array.from(e.clipboardData.items).filter((it) => it.kind === "file" && it.type.startsWith("image/"));
    if (items.length === 0) return;
    e.preventDefault();
    const textarea = e.currentTarget;
    const selStart = textarea.selectionStart;
    const selEnd = textarea.selectionEnd;
    const newPaths: string[] = [];
    for (const item of items) {
      const file = item.getAsFile();
      if (!file) continue;
      const buf = new Uint8Array(await file.arrayBuffer());
      try {
        const path = await saveClipboardImage(buf);
        newPaths.push(path);
      } catch (err) {
        useBoardStore.setState({ error: String(err) });
        return;
      }
    }
    const baseCount = imagePaths.length;
    const markers = newPaths.map((_, i) => imageMarker(baseCount + i + 1)).join(" ");
    const next = prompt.slice(0, selStart) + markers + prompt.slice(selEnd);
    setPrompt(next);
    setImagePaths([...imagePaths, ...newPaths]);
  };

  const removeImageAt = (idx: number) => {
    const { body, imagePaths: nextPaths } = removeImageAtIndex(prompt, imagePaths, idx);
    setPrompt(body);
    setImagePaths(nextPaths);
  };

  const cardProjects = [
    ...new Set(
      cards
        .map((c) => c.link.projectPath ?? c.session?.projectPath)
        .filter(Boolean) as string[]
    ),
  ];

  const projects = [...new Set([...settingsProjects, ...cardProjects])].slice(0, 30);

  useEffect(() => {
    promptRef.current?.focus();
    getSettings()
      .then((s) => {
        const paths = s.projects.map((p) => p.path).filter(Boolean);
        setSettingsProjects(paths);
        if (!project && paths.length > 0) {
          setProject(paths[0]);
        }
        setApiServices(s.apiServices ?? []);
        setDefaultAPIServiceIds(s.defaultAPIServiceIds ?? {});
      })
      .catch(console.error);
    if (cardProjects.length > 0 && !project) {
      setProject(cardProjects[0]);
    }
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!prompt.trim()) return;
    setSubmitting(true);
    try {
      const cardId = await createCard(
        prompt.trim(),
        title.trim() || null,
        project || ".",
        launch,
        assistantId,
        imagePaths.length > 0 ? imagePaths : undefined,
        apiServiceId,
      );
      setNewTaskOpen(false);
      if (launch && cardId) {
        selectCard(cardId);
      }
    } finally {
      setSubmitting(false);
    }
  };

  const inputStyle: React.CSSProperties = {
    background: c.bgInput,
    border: `1px solid ${c.border}`,
    color: c.textPrimary,
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center animate-fade-in"
      style={{ background: c.bgOverlay }}
      onClick={() => setNewTaskOpen(false)}
    >
      <div
        className="w-[520px] rounded-xl shadow-2xl animate-slide-up"
        style={{
          background: c.bgDialog,
          border: `1px solid ${c.borderBright}`,
        }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div
          className="flex items-center justify-between px-5 py-4"
          style={{ borderBottom: `1px solid ${c.border}` }}
        >
          <h2 className="text-[16px] font-semibold" style={{ color: c.textPrimary }}>New Task</h2>
          <button
            onClick={() => setNewTaskOpen(false)}
            className="transition-colors"
            style={{ color: c.textMuted }}
            onMouseEnter={(e) => { e.currentTarget.style.color = c.textPrimary; }}
            onMouseLeave={(e) => { e.currentTarget.style.color = c.textMuted; }}
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <form onSubmit={handleSubmit} className="px-5 py-5 flex flex-col gap-5">
          <div>
            <label className="block text-[13px] font-medium mb-2" style={{ color: c.textSecondary }}>Prompt</label>
            <textarea
              ref={promptRef}
              rows={4}
              placeholder="Describe the task for Claude..."
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              onPaste={handlePromptPaste}
              className="w-full rounded-lg px-3.5 py-3 text-[14px] outline-none resize-none transition-colors leading-relaxed"
              style={inputStyle}
            />
            {imagePaths.length > 0 && (
              <div className="flex flex-wrap gap-1.5 mt-2">
                {imagePaths.map((p, idx) => (
                  <span
                    key={p}
                    className="inline-flex items-center gap-1.5 rounded px-2 py-1 text-[11px]"
                    style={{ background: c.bgInput, color: c.textSecondary, border: `1px solid ${c.border}` }}
                    title={p}
                  >
                    <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 15.75l5.159-5.159a2.25 2.25 0 013.182 0l5.159 5.159m-1.5-1.5l1.409-1.409a2.25 2.25 0 013.182 0l2.909 2.909m-18 3.75h16.5a1.5 1.5 0 001.5-1.5V6a1.5 1.5 0 00-1.5-1.5H3.75A1.5 1.5 0 002.25 6v12a1.5 1.5 0 001.5 1.5zm10.5-11.25h.008v.008h-.008V8.25zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0z" />
                    </svg>
                    Image #{idx + 1}
                    <button
                      type="button"
                      onClick={() => removeImageAt(idx)}
                      className="ml-0.5 hover:text-red-400 transition-colors"
                      aria-label={`Remove image ${idx + 1}`}
                    >
                      <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
                      </svg>
                    </button>
                  </span>
                ))}
              </div>
            )}
          </div>

          <div>
            <label className="block text-[13px] font-medium mb-2" style={{ color: c.textSecondary }}>
              Title <span className="font-normal" style={{ color: c.textDim }}>(optional)</span>
            </label>
            <input
              type="text"
              placeholder="Short title for the board card"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              className="w-full rounded-lg px-3.5 py-2.5 text-[14px] outline-none transition-colors"
              style={inputStyle}
            />
          </div>

          <div>
            <label className="block text-[13px] font-medium mb-2" style={{ color: c.textSecondary }}>Project</label>
            {projects.length > 0 ? (
              <select
                value={project}
                onChange={(e) => setProject(e.target.value)}
                className="w-full rounded-lg px-3.5 py-2.5 text-[14px] outline-none transition-colors"
                style={inputStyle}
              >
                {projects.map((p) => (
                  <option key={p} value={p}>
                    {p.split(/[/\\]/).pop() ?? p}
                  </option>
                ))}
              </select>
            ) : (
              <input
                type="text"
                placeholder="C:\path\to\project"
                value={project}
                onChange={(e) => setProject(e.target.value)}
                className="w-full rounded-lg px-3.5 py-2.5 text-[14px] outline-none transition-colors"
                style={inputStyle}
              />
            )}
          </div>

          <div>
            <label className="block text-[13px] font-medium mb-2" style={{ color: c.textSecondary }}>
              Assistant
            </label>
            <div
              className="inline-flex items-center rounded-lg p-0.5"
              style={{ background: c.bgAccent("0.05"), border: `1px solid ${c.border}` }}
            >
              {(Object.keys(ASSISTANT_DISPLAY) as AssistantId[]).map((id) => {
                const active = assistantId === id;
                return (
                  <button
                    key={id}
                    type="button"
                    onClick={() => setAssistantId(id)}
                    className="px-3 py-1 rounded-md text-[12px] font-medium transition-colors"
                    style={{
                      background: active ? c.bgCard : "transparent",
                      color: active ? c.textPrimary : c.textMuted,
                      border: active ? `1px solid ${c.borderBright}` : "1px solid transparent",
                    }}
                  >
                    {ASSISTANT_DISPLAY[id]}
                  </button>
                );
              })}
            </div>
            {(assistantId === "gemini" || assistantId === "codex") && (
              <p className="mt-2 text-[11.5px]" style={{ color: c.textDim }}>
                {assistantId === "codex" ? "Codex" : "Gemini"} support is
                partial in this build — the embedded terminal invokes{" "}
                <code>{assistantId}</code> from PATH, and{" "}
                {assistantId === "codex"
                  ? "rollout sessions under ~/.codex/sessions are discovered."
                  : "sessions are listed only."}{" "}
                Activity detection and hooks remain Claude-only for now —
                full parity lands in follow-up sub-PRs of #124.
              </p>
            )}
          </div>

          {/* APIService picker — only render when at least one service exists
              for the chosen assistant. Eligible list excludes services bound
              to other assistants so launching never crosses streams. */}
          {apiServices.filter((s) => s.assistant === assistantId).length > 0 && (
            <div>
              <label className="block text-[13px] font-medium mb-2" style={{ color: c.textSecondary }}>
                API service
              </label>
              <select
                value={apiServiceId ?? ""}
                onChange={(e) => setApiServiceId(e.target.value || null)}
                className="w-full rounded-lg px-3.5 py-2.5 text-[14px] outline-none transition-colors"
                style={inputStyle}
              >
                <option value="">
                  {defaultAPIServiceIds[assistantId]
                    ? `Default — ${
                        apiServices.find((s) => s.id === defaultAPIServiceIds[assistantId])?.name ?? "configured default"
                      }`
                    : "Default — bare CLI"}
                </option>
                {apiServices
                  .filter((s) => s.assistant === assistantId)
                  .map((s) => (
                    <option key={s.id} value={s.id}>{s.name}</option>
                  ))}
              </select>
            </div>
          )}

          <label className="flex items-center gap-3 cursor-pointer select-none">
            <input
              type="checkbox"
              checked={launch}
              onChange={(e) => setLaunch(e.target.checked)}
              className="w-4 h-4 rounded accent-[#4f8ef7]"
            />
            <span className="text-[13px]" style={{ color: c.textSecondary }}>Start immediately in terminal</span>
          </label>

          <div className="flex gap-3 pt-1">
            <button
              type="button"
              onClick={() => setNewTaskOpen(false)}
              className="flex-1 py-2.5 rounded-lg text-[13px] transition-colors"
              style={{ border: `1px solid ${c.border}`, color: c.textMuted }}
              onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; e.currentTarget.style.color = c.textPrimary; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = ""; e.currentTarget.style.color = c.textMuted; }}
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!prompt.trim() || submitting}
              className="flex-1 py-2.5 rounded-lg bg-[#4f8ef7] hover:bg-[#5b97fa] disabled:opacity-40 text-white text-[13px] font-semibold transition-colors"
            >
              {submitting ? "Creating..." : launch ? "Create & Start" : "Create Task"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
