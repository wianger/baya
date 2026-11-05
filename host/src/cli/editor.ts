/**
 * The input of `baya attach`: a small line editor that knows wide
 * characters, so the box around it, the caret in it and CJK typed through
 * an input method all line up. Pure state; the screen draws it.
 */
import { charWidth } from "./tui.ts";

export class Editor {
  private chars: string[] = [];
  /** Caret, as an index into the characters. */
  private at = 0;
  private readonly history: string[] = [];
  private back = -1;
  private draft = "";

  get value(): string {
    return this.chars.join("");
  }

  get empty(): boolean {
    return this.chars.length === 0;
  }

  set(text: string): void {
    this.chars = [...text];
    this.at = this.chars.length;
  }

  insert(text: string): void {
    const added = [...text.replace(/\r\n?/gu, "\n")].filter((char) => char === "\n" || char >= " ");
    this.chars.splice(this.at, 0, ...added);
    this.at += added.length;
  }

  backspace(): void {
    if (this.at === 0) return;
    this.chars.splice(this.at - 1, 1);
    this.at--;
  }

  delete(): void {
    this.chars.splice(this.at, 1);
  }

  left(): void {
    this.at = Math.max(0, this.at - 1);
  }

  right(): void {
    this.at = Math.min(this.chars.length, this.at + 1);
  }

  /** To the start of the line the caret is on. */
  home(): void {
    while (this.at > 0 && this.chars[this.at - 1] !== "\n") this.at--;
  }

  end(): void {
    while (this.at < this.chars.length && this.chars[this.at] !== "\n") this.at++;
  }

  /** Ctrl+U: everything before the caret on its line. */
  killBefore(): void {
    const from = this.at;
    this.home();
    this.chars.splice(this.at, from - this.at);
  }

  /** Ctrl+K: everything after the caret on its line. */
  killAfter(): void {
    let to = this.at;
    while (to < this.chars.length && this.chars[to] !== "\n") to++;
    this.chars.splice(this.at, to - this.at);
  }

  /** Ctrl+W: the word before the caret. */
  killWord(): void {
    let from = this.at;
    while (from > 0 && /\s/u.test(this.chars[from - 1]!)) from--;
    while (from > 0 && !/\s/u.test(this.chars[from - 1]!)) from--;
    this.chars.splice(from, this.at - from);
    this.at = from;
  }

  /** Whether the caret is on the first (or last) line, where ↑ (↓) leaves it. */
  get onFirstLine(): boolean {
    return !this.chars.slice(0, this.at).includes("\n");
  }

  get onLastLine(): boolean {
    return !this.chars.slice(this.at).includes("\n");
  }

  /** ↑ in history: the message sent before. */
  previous(): void {
    if (this.history.length === 0) return;
    if (this.back === -1) this.draft = this.value;
    this.back = Math.min(this.history.length - 1, this.back + 1);
    this.set(this.history[this.history.length - 1 - this.back]!);
  }

  /** ↓ in history: the one after, then the draft. */
  next(): void {
    if (this.back === -1) return;
    this.back--;
    this.set(this.back === -1 ? this.draft : this.history[this.history.length - 1 - this.back]!);
  }

  /** Empties the editor, keeping what was sent for ↑. */
  take(): string {
    const text = this.value;
    if (text.trim() && this.history.at(-1) !== text) this.history.push(text);
    this.chars = [];
    this.at = 0;
    this.back = -1;
    this.draft = "";
    return text;
  }

  /**
   * The text as rows of at most [width] columns and the caret's row and
   * column among them. Lines wrap anywhere; a wide character never splits.
   */
  layout(width: number): { rows: string[]; row: number; column: number } {
    const rows: string[] = [""];
    let col = 0;
    let caret = { row: 0, column: 0 };
    for (let i = 0; i <= this.chars.length; i++) {
      if (i === this.at) caret = { row: rows.length - 1, column: col };
      if (i === this.chars.length) break;
      const char = this.chars[i]!;
      if (char === "\n") {
        rows.push("");
        col = 0;
        continue;
      }
      const w = charWidth(char.codePointAt(0)!);
      if (col + w > width) {
        rows.push("");
        col = 0;
        if (i === this.at) caret = { row: rows.length - 1, column: 0 };
      }
      rows[rows.length - 1] += char;
      col += w;
    }
    // A caret at the very end of a full row sits on the next.
    if (caret.column >= width) caret = { row: caret.row + 1, column: 0 };
    while (rows.length <= caret.row) rows.push("");
    return { rows, ...caret };
  }
}
