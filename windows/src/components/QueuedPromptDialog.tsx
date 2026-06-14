import { useState, useEffect, useRef } from "react";
import { useTheme, t } from "../theme";
import { saveClipboardImage, useBoardStore } from "../store/boardStore";
import { imageMarker, removeImageAtIndex } from "../lib/promptImageLayout";

interface Props {
  open: boolean;
  onClose: () => void;
  onSave: (body: string, sendAutomatically: boolean, imagePaths?: string[]) => void;
  /** If set, we're editing an existing prompt */
  editBody?: string;
  editSendAuto?: boolean;
  editImagePaths?: string[];
}

export default function QueuedPromptDialog({ open, onClose, onSave, editBody, editSendAuto, editImagePaths }: Props) {
  const { theme } = useTheme();
  const c = t(theme);
  const [body, setBody] = useState("");
  const [sendAuto, setSendAuto] = useState(true);
  const [imagePaths, setImagePaths] = useState<string[]>([]);
  const textRef = useRef<HTMLTextAreaElement>(null);
  const isEdit = editBody !== undefined;

  useEffect(() => {
    if (open) {
      setBody(editBody ?? "");
      setSendAuto(editSendAuto ?? true);
      setImagePaths(editImagePaths ?? []);
      setTimeout(() => textRef.current?.focus(), 50);
    }
  }, [open]);

  if (!open) return null;

  const canSave = body.trim().length > 0;

  const handleSubmit = () => {
    if (!canSave) return;
    onSave(body.trim(), sendAuto, imagePaths.length > 0 ? imagePaths : undefined);
    onClose();
  };

  const handlePaste = async (e: React.ClipboardEvent<HTMLTextAreaElement>) => {
    const items = Array.from(e.clipboardData.items).filter((it) => it.kind === "file" && it.type.startsWith("image/"));
    if (items.length === 0) return;
    e.preventDefault();
    const ta = e.currentTarget;
    const selStart = ta.selectionStart;
    const selEnd = ta.selectionEnd;
    const newPaths: string[] = [];
    for (const item of items) {
      const file = item.getAsFile();
      if (!file) continue;
      const buf = new Uint8Array(await file.arrayBuffer());
      try {
        newPaths.push(await saveClipboardImage(buf));
      } catch (err) {
        useBoardStore.setState({ error: String(err) });
        return;
      }
    }
    const baseCount = imagePaths.length;
    const markers = newPaths.map((_, i) => imageMarker(baseCount + i + 1)).join(" ");
    setBody(body.slice(0, selStart) + markers + body.slice(selEnd));
    setImagePaths([...imagePaths, ...newPaths]);
  };

  const removeImageAt = (idx: number) => {
    const next = removeImageAtIndex(body, imagePaths, idx);
    setBody(next.body);
    setImagePaths(next.imagePaths);
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
          width: 450,
          background: c.bgDialog,
          border: `1px solid ${c.border}`,
        }}
        onKeyDown={(e) => {
          if (e.key === "Escape") onClose();
          if ((e.metaKey || e.ctrlKey) && e.key === "Enter") handleSubmit();
        }}
      >
        {/* Header */}
        <div className="px-6 pt-5 pb-3">
          <h2 className="text-[16px] font-semibold" style={{ color: c.textPrimary }}>
            {isEdit ? "Edit Queued Prompt" : "Queue Prompt"}
          </h2>
          <p className="text-[12px] mt-1" style={{ color: c.textMuted }}>
            {isEdit ? "Update the prompt text and settings." : "Add a prompt to send to Claude later."}
          </p>
        </div>

        {/* Body */}
        <div className="px-6 py-3 flex flex-col gap-4">
          <textarea
            ref={textRef}
            value={body}
            onChange={(e) => setBody(e.target.value)}
            onPaste={handlePaste}
            placeholder="Enter your prompt..."
            className="w-full rounded-xl px-4 py-3 text-[13px] leading-[1.6] resize-none outline-none font-mono"
            style={{
              background: c.bgInput,
              color: c.textPrimary,
              border: `1px solid ${c.border}`,
              minHeight: 100,
              maxHeight: 250,
            }}
            onFocus={(e) => { e.currentTarget.style.borderColor = "rgba(79,142,247,0.4)"; }}
            onBlur={(e) => { e.currentTarget.style.borderColor = c.border; }}
          />
          {imagePaths.length > 0 && (
            <div className="flex flex-wrap gap-1.5">
              {imagePaths.map((p, idx) => (
                <span
                  key={p}
                  className="inline-flex items-center gap-1.5 rounded px-2 py-1 text-[11px]"
                  style={{ background: c.bgInput, color: c.textSecondary, border: `1px solid ${c.border}` }}
                  title={p}
                >
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

          <label
            className="flex items-center gap-2.5 cursor-pointer select-none"
            style={{ color: c.textSecondary }}
          >
            <input
              type="checkbox"
              checked={sendAuto}
              onChange={(e) => setSendAuto(e.target.checked)}
              className="w-4 h-4 rounded accent-[#4f8ef7]"
            />
            <span className="text-[13px]">Send automatically when Claude finishes</span>
          </label>
        </div>

        {/* Footer */}
        <div className="px-6 pb-5 pt-3 flex justify-end gap-2.5">
          <button
            onClick={onClose}
            className="h-9 px-4 rounded-lg text-[13px] font-medium transition-all duration-150"
            style={{ color: c.textSecondary, border: `1px solid ${c.border}` }}
            onMouseEnter={(e) => { e.currentTarget.style.background = c.hoverBg; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = ""; }}
          >
            Cancel
          </button>
          <button
            onClick={handleSubmit}
            disabled={!canSave}
            className="h-9 px-5 rounded-lg text-[13px] font-semibold transition-all duration-150 disabled:opacity-40"
            style={{ background: "#4f8ef7", color: "#fff" }}
            onMouseEnter={(e) => { if (canSave) e.currentTarget.style.background = "#5e9aff"; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = "#4f8ef7"; }}
          >
            {isEdit ? "Save" : "Add"}
          </button>
        </div>
      </div>
    </div>
  );
}
