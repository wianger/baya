/**
 * `@` mentions in `baya attach`: typing `@src/` lists what is in that folder
 * of the session, a file chosen goes with the message as a link to it, the
 * way a file attached on the phone does.
 */
import { pathToFileURL } from "node:url";
import type { Json } from "../acp/jsonrpc.ts";

export type FileEntry = { name: string; path: string; type: "file" | "directory" };
export type Listing = { root: string; path: string; entries: FileEntry[] };

/** The `@…` being typed at the caret, without its `@`. */
export function mentionAt(before: string): string | null {
  const match = /(?:^|\s)@([^\s@]*)$/u.exec(before);
  return match ? match[1]! : null;
}

/** Folders of what was built or installed, rarely the one meant. */
const BUILT = new Set([
  "node_modules",
  "build",
  "dist",
  "out",
  "target",
  "coverage",
  "vendor",
  "__pycache__",
]);

/**
 * Entries of a folder that the typed part starts, then contains; built and
 * installed folders last.
 */
export function matching(entries: FileEntry[], typed: string, limit = 8): FileEntry[] {
  const built = (e: FileEntry) => e.type === "directory" && BUILT.has(e.name);
  entries = [...entries.filter((e) => !built(e)), ...entries.filter(built)];
  const lower = typed.toLowerCase();
  const starts = entries.filter((e) => e.name.toLowerCase().startsWith(lower));
  const contains = lower
    ? entries.filter((e) => !starts.includes(e) && e.name.toLowerCase().includes(lower))
    : [];
  return [...starts, ...contains].slice(0, limit);
}

export class Mentions {
  /** Folders listed, by their path in the session (`` for its root). */
  private readonly listed = new Map<string, FileEntry[] | "loading" | "missing">();
  private root = "";
  /** Files chosen, by the path typed after `@`, to their full path. */
  private readonly chosen = new Map<string, string>();

  private readonly list: (path?: string) => Promise<Listing>;
  private readonly changed: () => void;

  constructor(list: (path?: string) => Promise<Listing>, changed: () => void) {
    this.list = list;
    this.changed = changed;
  }

  /** What fits the `@…` typed, or null while there is none. */
  options(typed: string): FileEntry[] | null {
    const slash = typed.lastIndexOf("/");
    const folder = slash < 0 ? "" : typed.slice(0, slash);
    const known = this.listed.get(folder);
    if (known === undefined) {
      this.load(folder);
      return null;
    }
    if (known === "loading" || known === "missing") return null;
    return matching(known, typed.slice(slash + 1));
  }

  /** The text to put in place of the `@…` for [entry] in it. */
  complete(typed: string, entry: FileEntry): string {
    const slash = typed.lastIndexOf("/");
    const path = `${slash < 0 ? "" : typed.slice(0, slash + 1)}${entry.name}`;
    if (entry.type === "directory") return `@${path}/`;
    this.chosen.set(path, entry.path);
    return `@${path} `;
  }

  /** Links to the files chosen that are still in [text]. */
  links(text: string): Json[] {
    const seen = new Set<string>();
    const links: Json[] = [];
    for (const match of text.matchAll(/(?:^|\s)@([^\s@]+)/gu)) {
      const full = this.chosen.get(match[1]!);
      if (!full || seen.has(full)) continue;
      seen.add(full);
      links.push({
        type: "resource_link",
        name: full.split(/[/\\]/u).pop()!,
        uri: pathToFileURL(full).href,
      });
    }
    return links;
  }

  /** Folders change as the agent works: list them afresh from now on. */
  forget(): void {
    for (const [folder, state] of this.listed) {
      if (state !== "loading") this.listed.delete(folder);
    }
  }

  private load(folder: string): void {
    this.listed.set(folder, "loading");
    const sep = this.root.includes("\\") ? "\\" : "/";
    const path =
      folder && this.root ? `${this.root}${sep}${folder.split("/").join(sep)}` : undefined;
    if (folder && !this.root) {
      // The root comes with the first listing; ask again once it is in.
      this.listed.delete(folder);
      if (!this.listed.has("")) this.load("");
      return;
    }
    this.list(path).then(
      (listing) => {
        if (!folder) this.root = listing.root;
        this.listed.set(folder, listing.entries);
        this.changed();
      },
      () => {
        this.listed.set(folder, "missing");
        this.changed();
      },
    );
  }
}
