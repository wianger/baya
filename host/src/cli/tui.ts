/**
 * Drawing for `baya attach`: colours by value (true colour where the
 * terminal has it, 256 otherwise), widths that count CJK and emoji as two
 * columns, wrapping that keeps a hanging indent, boxes, rules and markdown a
 * line at a time. Nothing here relies on "dim", which terminals render too
 * differently to design with.
 */

const ESC = "\x1b[";

export const isTty = (): boolean => Boolean(process.stdout.isTTY);

const trueColor = (): boolean =>
  /truecolor|24bit/iu.test(process.env["COLORTERM"] ?? "") ||
  Boolean(process.env["WT_SESSION"]) ||
  process.env["TERM_PROGRAM"] === "vscode";

type Rgb = readonly [number, number, number];

function to256([r, g, b]: Rgb): number {
  const level = (v: number) => (v < 48 ? 0 : v < 115 ? 1 : Math.floor((v - 35) / 40));
  if (Math.abs(r - g) < 10 && Math.abs(g - b) < 10) {
    if (r < 8) return 16;
    if (r > 248) return 231;
    return 232 + Math.round(((r - 8) / 247) * 23);
  }
  return 16 + 36 * level(r) + 6 * level(g) + level(b);
}

function fg(rgb: Rgb): (text: string) => string {
  return (text) => {
    if (!isTty() || text === "") return text;
    const code = trueColor() ? `38;2;${rgb[0]};${rgb[1]};${rgb[2]}` : `38;5;${to256(rgb)}`;
    return `${ESC}${code}m${text}${ESC}39m`;
  };
}

/** The terminal's background is light (from COLORFGBG, when it says). */
function lightTerminal(): boolean {
  const bg = Number((process.env["COLORFGBG"] ?? "").split(";").pop());
  return bg === 7 || bg === 15;
}

function bgCode(rgb: Rgb): string {
  return trueColor() ? `48;2;${rgb[0]};${rgb[1]};${rgb[2]}` : `48;5;${to256(rgb)}`;
}

/**
 * [text] on a soft band of colour to the edge of [width]: how a sent
 * message stands apart from the replies.
 */
export function band(text: string, width: number): string {
  if (!isTty()) return text;
  const tone: Rgb = lightTerminal() ? [236, 236, 241] : [38, 38, 46];
  const pad = Math.max(0, width - textWidth(text));
  // Keep the band through any resets inside the text.
  const open = `${ESC}${bgCode(tone)}m`;
  return `${open}${text.replaceAll(`${ESC}0m`, `${ESC}0m${open}`)}${" ".repeat(pad)}${ESC}49m`;
}

/** [text] in a colour that runs from [from] to [to] across its letters. */
export function gradient(text: string, from: Rgb, to: Rgb): string {
  if (!isTty() || !trueColor()) return c.bold(c.accent(text));
  const chars = [...text];
  return chars
    .map((char, i) => {
      const t = chars.length > 1 ? i / (chars.length - 1) : 0;
      const mix = from.map((v, k) => Math.round(v + (to[k]! - v) * t)) as unknown as Rgb;
      return `${ESC}38;2;${mix[0]};${mix[1]};${mix[2]}m${char}`;
    })
    .join("")
    .concat(`${ESC}39m`);
}

/**
 * [text] with a light sweeping across it, one step per [frame]: the live
 * "Thinking…" every agent terminal now has.
 */
export function shimmer(text: string, frame: number): string {
  if (!isTty()) return text;
  const chars = [...text];
  const span = chars.length + 8;
  const head = (frame % span) - 4;
  const base: Rgb = [232, 180, 74];
  const lit: Rgb = [255, 236, 190];
  return chars
    .map((char, i) => {
      const glow = Math.max(0, 1 - Math.abs(i - head) / 4);
      const rgb = base.map((v, k) => Math.round(v + (lit[k]! - v) * glow)) as unknown as Rgb;
      return (
        (trueColor() ? `${ESC}38;2;${rgb[0]};${rgb[1]};${rgb[2]}m` : `${ESC}38;5;${to256(rgb)}m`) +
        char
      );
    })
    .join("")
    .concat(`${ESC}39m`);
}

const attr = (open: number, close: number) => (text: string) =>
  isTty() && text !== "" ? `${ESC}${open}m${text}${ESC}${close}m` : text;

/** Baya's colours, mid-tones that read on dark and light terminals alike. */
export const c = {
  accent: fg([232, 180, 74]),
  text: (text: string) => text,
  muted: fg([142, 142, 152]),
  faint: fg([98, 98, 110]),
  green: fg([126, 198, 153]),
  red: fg([236, 126, 126]),
  blue: fg([122, 162, 247]),
  violet: fg([195, 154, 220]),
  code: fg([121, 192, 208]),
  bold: attr(1, 22),
  italic: attr(3, 23),
};

// biome-ignore lint/suspicious/noControlCharactersInRegex: matches ANSI escapes.
const ANSI = /\x1b\[[0-9;]*[A-Za-z]/gu;

export function charWidth(code: number): number {
  if (code < 32 || (code >= 0x300 && code <= 0x36f) || code === 0x200d || code === 0xfe0f) {
    return 0;
  }
  const wide =
    (code >= 0x1100 && code <= 0x115f) ||
    (code >= 0x2e80 && code <= 0xa4cf) ||
    (code >= 0xac00 && code <= 0xd7a3) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0xfe30 && code <= 0xfe4f) ||
    (code >= 0xff00 && code <= 0xff60) ||
    (code >= 0xffe0 && code <= 0xffe6) ||
    (code >= 0x1f300 && code <= 0x1faff) ||
    (code >= 0x20000 && code <= 0x3fffd);
  return wide ? 2 : 1;
}

/** Columns [text] takes: wide (CJK, full-width, emoji) characters take two. */
export function textWidth(text: string): number {
  let width = 0;
  for (const char of text.replace(ANSI, "")) width += charWidth(char.codePointAt(0)!);
  return width;
}

/** The terminal's width, kept sane. */
function columns(): number {
  return Math.max(30, Math.min(process.stdout.columns || 80, 160));
}

/**
 * [text] broken into rows of at most [width] columns: at spaces where it
 * can, anywhere between wide characters, never inside an escape. Colours
 * carry over, since a row ends with a reset and the next starts with the
 * styles that were open.
 */
export function wrap(text: string, width: number): string[] {
  if (width <= 0 || textWidth(text) <= width) return [text];
  // biome-ignore lint/suspicious/noControlCharactersInRegex: matches ANSI escapes.
  const tokens = text.match(/\x1b\[[0-9;]*[A-Za-z]|[\s\S]/gu) ?? [];
  const rows: string[] = [];
  let row = "";
  let rowWidth = 0;
  let open: string[] = [];
  let lastSpace = -1;
  const flush = (cut: number) => {
    const head = row.slice(0, cut).replace(/\s+$/u, "");
    const tail = row.slice(cut).replace(/^\s+/u, "");
    rows.push(open.length ? `${head}${ESC}0m` : head);
    row = open.join("") + tail;
    rowWidth = textWidth(tail);
    lastSpace = -1;
  };
  for (const token of tokens) {
    if (token.startsWith("\x1b[")) {
      row += token;
      // biome-ignore lint/suspicious/noControlCharactersInRegex: matches ANSI escapes.
      if (/\x1b\[(0|22|23|39)m/u.test(token)) {
        open = token === `${ESC}0m` ? [] : open.slice(0, -1);
      } else {
        open.push(token);
      }
      continue;
    }
    const w = charWidth(token.codePointAt(0)!);
    if (rowWidth + w > width) {
      if (lastSpace > 0 && w === 1 && token !== " ") flush(lastSpace);
      else flush(row.length);
    }
    if (token === " ") lastSpace = row.length;
    row += token;
    rowWidth += w;
  }
  if (row.replace(ANSI, "") !== "") rows.push(row);
  return rows;
}

/** [text] wrapped to the screen, the first row after [first], the rest after [rest]. */
export function hang(text: string, first: string, rest: string, width = columns()): string[] {
  const rows = wrap(text, width - textWidth(first));
  return rows.map((row, i) => (i === 0 ? first : rest) + row);
}

/** A rounded box of [lines], [title] in its top edge and [foot] in its bottom. */
export function box(
  lines: string[],
  options: { title?: string; foot?: string; color?: (text: string) => string; width?: number },
): string[] {
  const paint = options.color ?? c.faint;
  const width = Math.min(options.width ?? columns() - 2, columns() - 2);
  const inner = width - 4;
  const edge = (left: string, label: string | undefined, right: string) => {
    const tag = label ? ` ${label} ` : "";
    const fill = Math.max(0, width - 2 - textWidth(tag) - 1);
    return paint(`${left}─`) + tag + paint(`${"─".repeat(fill)}${right}`);
  };
  const out = [edge("╭", options.title, "╮")];
  for (const line of lines) {
    for (const row of wrap(line, inner)) {
      const pad = Math.max(0, inner - textWidth(row));
      out.push(`${paint("│")} ${row}${" ".repeat(pad)} ${paint("│")}`);
    }
  }
  out.push(edge("╰", options.foot, "╯"));
  return out;
}

/** ▰▰▰▱▱ for [fraction]. */
export function meter(fraction: number, cells = 6): string {
  const full = Math.max(0, Math.min(cells, Math.round(fraction * cells)));
  const paint = fraction > 0.8 ? c.red : fraction > 0.6 ? c.accent : c.muted;
  return paint("▰".repeat(full)) + c.faint("▱".repeat(cells - full));
}

// ── markdown ─────────────────────────────────────────────────────────────────

/** Inline markdown: `code`, **bold**, *emphasis*, [links](url). */
function inline(text: string): string {
  return text
    .replace(/`([^`]+)`/gu, (_, code: string) => c.code(code))
    .replace(/\*\*([^*]+)\*\*/gu, (_, strong: string) => c.bold(strong))
    .replace(
      /\[([^\]]+)\]\(([^)]+)\)/gu,
      (_, label: string, url: string) => `${c.blue(label)} ${c.faint(url)}`,
    )
    .replace(
      /(^|[^*\w])\*([^*\s][^*]*)\*(?!\w)/gu,
      (_, before: string, em: string) => before + c.italic(em),
    );
}

const FENCE = /^\s*```/u;

/**
 * Markdown a line at a time, as rows already wrapped with a hanging indent
 * under [indent]: headings, lists, quotes, rules and fenced code.
 */
export class MarkdownLines {
  private fenced = false;
  private readonly indent: string;

  constructor(indent = "  ") {
    this.indent = indent;
  }

  /** A finished line, which may open or close a fence. */
  line(text: string): string[] {
    if (FENCE.test(text)) {
      const opening = !this.fenced;
      this.fenced = opening;
      return [this.fence(text, opening)];
    }
    return this.render(text, this.fenced);
  }

  /** The line still being written, shown without changing any state. */
  preview(text: string): string[] {
    return FENCE.test(text) ? [this.fence(text, !this.fenced)] : this.render(text, this.fenced);
  }

  reset(): void {
    this.fenced = false;
  }

  private fence(text: string, opening: boolean): string {
    const language = text.trim().slice(3);
    return this.indent + (opening ? c.faint(`╭─ ${language || "code"}`) : c.faint("╰─"));
  }

  private render(text: string, fenced: boolean): string[] {
    const at = this.indent;
    if (fenced) return hang(c.code(text), `${at}${c.faint("│")} `, `${at}${c.faint("│")} `);
    if (text.trim() === "") return [""];
    const heading = /^(#{1,6})\s+(.*)$/u.exec(text);
    if (heading) {
      const style = heading[1]!.length <= 2 ? (t: string) => c.bold(c.accent(t)) : c.bold;
      return hang(style(heading[2]!), at, at);
    }
    const bullet = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/u.exec(text);
    if (bullet) {
      const depth = " ".repeat(Math.min(bullet[1]!.length, 8));
      const mark = /\d/u.test(bullet[2]!) ? c.muted(bullet[2]!) : c.accent("•");
      const lead = `${at}${depth}${mark} `;
      return hang(inline(bullet[3]!), lead, " ".repeat(textWidth(lead)));
    }
    const quote = /^>\s?(.*)$/u.exec(text);
    if (quote)
      return hang(
        c.italic(c.muted(inline(quote[1]!))),
        `${at}${c.faint("▏")} `,
        `${at}${c.faint("▏")} `,
      );
    if (/^\s*([-*_])\1{2,}\s*$/u.test(text)) return [at + c.faint("─".repeat(24))];
    if (/^\s*\|.*\|\s*$/u.test(text)) {
      if (/^\s*\|[\s:|-]+\|\s*$/u.test(text))
        return [at + c.faint(text.trim().replace(/[^|]/gu, "─"))];
      return [at + text.trim().replace(/\|/gu, c.faint("│"))];
    }
    return hang(inline(text), at, at);
  }
}

// ── diffs ────────────────────────────────────────────────────────────────────

/**
 * The changed lines between [before] and [after] with a line of context
 * around them, as rows: removed in red, added in green, the rest muted.
 */
export function diffRows(before: string, after: string, limit = 14): string[] {
  const a = before.split("\n");
  const b = after.split("\n");
  if (a.length * b.length > 250_000)
    return [c.muted(`  ${b.length - a.length >= 0 ? "+" : ""}${b.length - a.length} lines`)];
  // Longest common subsequence, then walk it.
  const lcs: number[][] = Array.from({ length: a.length + 1 }, () =>
    new Array<number>(b.length + 1).fill(0),
  );
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i]![j] =
        a[i] === b[j] ? lcs[i + 1]![j + 1]! + 1 : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!);
    }
  }
  const ops: Array<[" " | "-" | "+", string]> = [];
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      ops.push([" ", a[i]!]);
      i++;
      j++;
    } else if (i < a.length && (j >= b.length || lcs[i + 1]![j]! >= lcs[i]![j + 1]!)) {
      // Removed before added, as diffs read.
      ops.push(["-", a[i]!]);
      i++;
    } else {
      ops.push(["+", b[j]!]);
      j++;
    }
  }
  // A change, or a line next to one.
  const changed = (k: number) => (ops[k]?.[0] ?? " ") !== " ";
  const keep = ops.map((_, k) => changed(k) || changed(k - 1) || changed(k + 1));
  const rows: string[] = [];
  let skipped = false;
  ops.forEach(([op, line], k) => {
    if (!keep[k]) {
      if (!skipped) rows.push(c.faint("  ⋮"));
      skipped = true;
      return;
    }
    skipped = false;
    if (op === "+") rows.push(c.green(`+ ${line}`));
    else if (op === "-") rows.push(c.red(`- ${line}`));
    else rows.push(c.faint(`  ${line}`));
  });
  if (rows.length > limit) {
    return [...rows.slice(0, limit), c.faint(`  … ${rows.length - limit} more lines`)];
  }
  return rows;
}
