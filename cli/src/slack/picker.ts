/// Detect Claude Code's interactive numbered picker in a tmux pane snapshot
/// so the bridge can mirror the choices as Slack interactive buttons.
///
/// The picker has a stable shape:
///   <question>
///   ❯ 1. <title>
///        <description>
///     2. <title>
///        <description>
///     ...
///     N-1. Type something.
///     N.   Chat about this
///   Enter to select · Tab/Arrow keys to navigate · Esc to cancel
///
/// We anchor on that footer (it never appears in regular tool output) and
/// then walk up. The "Type something." and "Chat about this" entries are
/// keyboard-only escape hatches — they always trail the real options, so we
/// drop them from the Slack buttons. Same for the highlighted-line caret (❯).

const ANSI_RE = /\x1b\[[0-9;]*[A-Za-z]/g;
const BOX_DECOR_RE = /^[\s─-╿]+$/;
const PICKER_FOOTER = "Enter to select";
/// Two trailing escape-hatch options that we never expose as Slack buttons.
const ESCAPE_HATCH_TITLES = ["Type something.", "Chat about this"];

export interface PickerOption {
  number: number;
  title: string;
  description?: string;
}

export interface Picker {
  question: string;
  options: PickerOption[];
  /// Stable fingerprint of (question + option titles) so callers can dedupe
  /// across poll ticks and avoid reposting the same picker every tick.
  hash: string;
}

/// Strip the ANSI CSI escape sequences tmux emits when we capture with -e.
export function stripAnsi(s: string): string {
  return s.replace(ANSI_RE, "");
}

/// Locate the picker block in the pane snapshot, returning null when none is
/// active. We anchor on the bottom-most `❯ N. <text>` line — Claude Code only
/// uses that caret for the active picker, so it's a high-precision signal
/// across both picker variants (with or without the `Enter to select` footer
/// and the Type-something / Chat-about-this escape hatches).
export function parsePicker(paneText: string): Picker | null {
  const lines = paneText.split("\n").map((l) => stripAnsi(l).trimEnd());

  // 1. Bottom-most caret line. If a stale picker is still in scrollback its
  // caret is earlier, so the bottom-most one is the active picker.
  let caretIdx = -1;
  for (let i = lines.length - 1; i >= 0; i--) {
    const t = lines[i].trim();
    if ((t.startsWith("❯") || t.startsWith("›")) && parseNumberedLine(t)) {
      caretIdx = i;
      break;
    }
  }
  if (caretIdx < 0) return null;

  // 2. Expand the picker block bounds outward from the caret. A picker block
  // is a contiguous run of (numbered | indented | decor) lines. A blank line
  // terminates the block on either side; the line just above the block is
  // the question. The footer line (if present) also terminates.
  const isPickerLine = (i: number): boolean => {
    const line = lines[i];
    const trimmed = line.trim();
    if (!trimmed) return false;
    if (trimmed.includes(PICKER_FOOTER)) return false;
    if (parseNumberedLine(trimmed)) return true;
    if (BOX_DECOR_RE.test(line)) return true;
    if (line.startsWith("     ") || line.startsWith("\t")) return true;
    return false;
  };
  let start = caretIdx;
  while (start > 0 && isPickerLine(start - 1)) start--;
  let end = caretIdx;
  while (end < lines.length - 1 && isPickerLine(end + 1)) end++;

  // 3. The question is the first non-blank, non-decor line above the block.
  let question = "";
  for (let i = start - 1; i >= 0; i--) {
    const line = lines[i];
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (BOX_DECOR_RE.test(line)) continue;
    question = trimmed;
    break;
  }

  // 4. Linear parse of the block: numbered lines start options, indented
  // lines append to the current option's description, decor lines are skipped.
  type Raw = { number: number; title: string; descLines: string[] };
  const raw: Raw[] = [];
  let current: Raw | null = null;
  for (let i = start; i <= end; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (BOX_DECOR_RE.test(line) || !trimmed) continue;
    const m = parseNumberedLine(trimmed);
    if (m) {
      if (current) raw.push(current);
      current = { number: m.number, title: m.title, descLines: [] };
      continue;
    }
    if (current && (line.startsWith("     ") || line.startsWith("\t"))) {
      current.descLines.push(trimmed);
    }
  }
  if (current) raw.push(current);
  if (raw.length === 0) return null;
  return assemble(question, raw);
}

function parseNumberedLine(s: string): { number: number; title: string } | null {
  // Optional caret prefix (❯ or ›), then `N. title`. Picker numbers are
  // always single-digit so an arbitrary "1234." in a tool output line does
  // not trip the detector.
  let body = s;
  if (body.startsWith("❯") || body.startsWith("›")) body = body.slice(1).trim();
  const m = /^(\d{1,2})\.\s+(.+)$/.exec(body);
  if (!m) return null;
  const number = parseInt(m[1], 10);
  if (number < 1 || number > 20) return null;
  return { number, title: m[2].trim() };
}

function assemble(question: string, raw: { number: number; title: string; descLines: string[] }[]): Picker | null {
  const sorted = [...raw].sort((a, b) => a.number - b.number);
  const filtered = sorted.filter((o) => !ESCAPE_HATCH_TITLES.some((t) => o.title.startsWith(t)));
  if (filtered.length === 0) return null;
  const options: PickerOption[] = filtered.map((o) => ({
    number: o.number,
    title: o.title,
    description: o.descLines.length ? o.descLines.join(" ") : undefined,
  }));
  const hashSource = [question, ...options.map((o) => `${o.number}.${o.title}`)].join("\n");
  return { question, options, hash: fnv1a(hashSource) };
}

/// 32-bit FNV-1a — fine for dedupe across a handful of poll ticks; we are
/// not relying on it for security.
function fnv1a(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}
