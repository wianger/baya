import { stripVTControlCharacters, styleText } from "node:util";

/**
 * Terminal presentation. Color only on a TTY and never with NO_COLOR
 * (`styleText` checks both); `--json` output never passes through here.
 */
type Style = Parameters<typeof styleText>[0];

const paint = (style: Style) => (text: string) =>
  styleText(style, text, { stream: process.stdout });

export const bold = paint("bold");
export const dim = paint("dim");
export const green = paint("green");
export const yellow = paint("yellow");
export const red = paint("red");
export const cyan = paint("cyan");

export const ok = (text: string) => `${green("✓")} ${text}`;
export const warn = (text: string) => `${yellow("!")} ${text}`;
export const fail = (text: string) => `${red("✗")} ${text}`;
/** A follow-up command the user can copy. */
export const hint = (text: string) => `  ${dim("→")} ${text}`;

export function out(...lines: string[]): void {
  process.stdout.write(`${lines.join("\n")}\n`);
}

/** Columns padded to the widest cell, ignoring ANSI escape codes. */
export function table(rows: string[][]): string[] {
  const visible = (cell: string) => stripVTControlCharacters(cell).length;
  const widths: number[] = [];
  for (const row of rows) {
    row.forEach((cell, index) => {
      widths[index] = Math.max(widths[index] ?? 0, visible(cell));
    });
  }
  return rows.map((row) =>
    row
      .map((cell, index) =>
        index === row.length - 1 ? cell : cell + " ".repeat(widths[index]! - visible(cell)),
      )
      .join("  ")
      .trimEnd(),
  );
}

/** "3m", "2h 5m", "4d 1h" */
export function duration(ms: number): string {
  const minutes = Math.max(0, Math.floor(ms / 60_000));
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ${minutes % 60}m`;
  return `${Math.floor(hours / 24)}d ${hours % 24}h`;
}

/** Closest known word within two edits, for "did you mean". */
export function suggest(input: string, known: readonly string[]): string | undefined {
  let best: { word: string; distance: number } | undefined;
  for (const word of known) {
    const distance = editDistance(input, word);
    if (distance <= 2 && (!best || distance < best.distance)) best = { word, distance };
  }
  return best?.word;
}

/** Optimal string alignment: a swap of neighbouring letters is one edit. */
function editDistance(a: string, b: string): number {
  const d = Array.from({ length: a.length + 1 }, (_, i) =>
    Array.from({ length: b.length + 1 }, (_, j) => (i === 0 ? j : j === 0 ? i : 0)),
  );
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let best = Math.min(d[i - 1]![j]! + 1, d[i]![j - 1]! + 1, d[i - 1]![j - 1]! + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        best = Math.min(best, d[i - 2]![j - 2]! + 1);
      }
      d[i]![j] = best;
    }
  }
  return d[a.length]![b.length]!;
}
