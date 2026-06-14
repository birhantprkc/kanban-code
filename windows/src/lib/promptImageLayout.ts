// TypeScript port of Sources/KanbanCodeCore/UseCases/PromptImageLayout.swift
//
// Image positions in a prompt are stored as plain-text markers like `[Image #1]`.
// On send we replace those markers with markdown image refs (`![](path)`) — the
// macOS app uses a tmux clipboard-paste dance for assistants that support it,
// but the markdown fallback is the simpler universal path and matches what the
// Mac code already falls back to when no inline markers are present.

export interface PromptPart {
  text: string;
  /** Zero-based image index. undefined when this part is plain text. */
  imageIndex?: number;
}

export const IMAGE_MARKER_PREFIX = "[Image #";

export function imageMarker(index1Based: number): string {
  return `[Image #${index1Based}]`;
}

export function parts(text: string, imageCount: number): PromptPart[] {
  if (imageCount <= 0 || !text.includes(IMAGE_MARKER_PREFIX)) {
    return text.length === 0 ? [] : [{ text }];
  }

  const out: PromptPart[] = [];
  let cursor = 0;
  while (cursor < text.length) {
    const markerStart = text.indexOf(IMAGE_MARKER_PREFIX, cursor);
    if (markerStart === -1) break;
    const markerEnd = text.indexOf("]", markerStart);
    if (markerEnd === -1) break;

    const numberText = text.slice(markerStart + IMAGE_MARKER_PREFIX.length, markerEnd);
    const number = Number.parseInt(numberText, 10);
    if (!Number.isFinite(number) || number < 1 || number > imageCount) {
      // Not a valid marker — keep as plain text and advance.
      out.push({ text: text.slice(cursor, markerEnd + 1) });
      cursor = markerEnd + 1;
      continue;
    }

    if (markerStart > cursor) {
      out.push({ text: text.slice(cursor, markerStart) });
    }
    out.push({ text: "", imageIndex: number - 1 });
    cursor = markerEnd + 1;
  }
  if (cursor < text.length) {
    out.push({ text: text.slice(cursor) });
  }
  return coalesceAdjacentText(out);
}

export function referencedImageIndices(text: string, imageCount: number): number[] {
  return parts(text, imageCount)
    .map((p) => p.imageIndex)
    .filter((i): i is number => i != null);
}

/** Rewrite the prompt so markers point at the given image paths as markdown
 *  refs. When the prompt has no markers and there are images, the refs are
 *  appended after the text — matches macOS PromptImageLayout. */
export function replaceMarkersWithMarkdown(text: string, imagePaths: string[]): string {
  const ps = parts(text, imagePaths.length);
  const hasInline = ps.some((p) => p.imageIndex != null);
  if (!hasInline) {
    if (imagePaths.length === 0) return text;
    const refs = imagePaths.map((p) => `![](${p})`).join("\n");
    return text.length === 0 ? refs : `${text}\n${refs}`;
  }
  return ps
    .map((p) => (p.imageIndex != null ? `![](${imagePaths[p.imageIndex]})` : p.text))
    .join("");
}

/** Drop image `removedIdx` (0-based) and rewrite the body's markers so the
 *  remaining attachments stay contiguous 1-based. Used by the chip-remove
 *  button on both the New Task and Queued Prompt dialogs.
 *
 *  Returns the new body + the new paths. Doing this purely so the editor
 *  state stays in sync with what `replaceMarkersWithMarkdown` would emit at
 *  send time — without the renumber, a higher-numbered marker silently
 *  becomes literal text on send and that image gets lost. */
export function removeImageAtIndex(
  body: string,
  imagePaths: string[],
  removedIdx: number,
): { body: string; imagePaths: string[] } {
  if (removedIdx < 0 || removedIdx >= imagePaths.length) {
    return { body, imagePaths };
  }
  const nextPaths = imagePaths.filter((_, i) => i !== removedIdx);
  let nextBody = body.split(imageMarker(removedIdx + 1)).join("");
  // Shift every marker > removedIdx down by one. Walk in ascending order so
  // we never collide with a not-yet-shifted higher number (since the new
  // values are strictly smaller than the source values).
  for (let i = removedIdx + 1; i < imagePaths.length; i++) {
    nextBody = nextBody.split(imageMarker(i + 1)).join(imageMarker(i));
  }
  return { body: nextBody, imagePaths: nextPaths };
}

function coalesceAdjacentText(items: PromptPart[]): PromptPart[] {
  const out: PromptPart[] = [];
  for (const p of items) {
    const last = out[out.length - 1];
    if (p.imageIndex == null && last && last.imageIndex == null) {
      last.text += p.text;
    } else {
      out.push({ ...p });
    }
  }
  return out;
}
