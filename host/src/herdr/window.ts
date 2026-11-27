/**
 * The herdr-app window (herdr's desktop app): spaces, tabs and panes over
 * herdr-core's terminals. A terminal labelled `herdr.space=<id>` shows up in
 * that space, so Baya starts each agent with herdr-core and the label, and
 * the person sees it in the window. Reads and keys go through herdr-core.
 */
import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Json } from "../acp/jsonrpc.ts";
import { folderName } from "../session/registry.ts";
import { findExecutable } from "../workspace/directories.ts";
import type { PaneAgent, PaneHost } from "./app.ts";
import { type HerdrCore, herdr } from "./core.ts";

/** Labels Baya puts on the terminals it starts. */
const AGENT = "baya.agent";
const AGENT_SESSION = "baya.agent_session";
const SPACE = "herdr.space";

/** Agents that take their conversation's id at start. */
const PRESET_ID = new Set(["claude", "pi"]);

const sameFolder = (a: string, b: string) => {
  const norm = (p: string) => p.replace(/[\\/]+$/u, "").toLowerCase();
  return norm(a) === norm(b);
};

/** One word for a shell line, quoted where it needs to be. */
const quote = (word: string) =>
  /^[\w./:=@-]+$/u.test(word) ? word : `"${word.replace(/"/gu, '\\"')}"`;

interface SpaceInfo {
  id: string;
  name: string;
  folder: string;
}

export class HerdrWindow implements PaneHost {
  private readonly core: HerdrCore;
  private spaces: { at: number; list: SpaceInfo[] } = { at: 0, list: [] };

  constructor(core: HerdrCore = herdr) {
    this.core = core;
  }

  async available(): Promise<boolean> {
    return this.core.available();
  }

  async prepare(): Promise<void> {}

  async agents(): Promise<PaneAgent[]> {
    const listed = await this.core.call("terminal.list", {});
    const terminals = (listed["terminals"] as Json[] | undefined) ?? [];
    const spaces = await this.spaceList();
    return terminals.flatMap((terminal) => {
      const labels = (terminal["labels"] as Record<string, string> | undefined) ?? {};
      const space = labels[SPACE];
      const status = terminal["status"] as Json | null | undefined;
      const agent = labels[AGENT] ?? (typeof status?.["app"] === "string" ? status["app"] : "");
      // In the window, and an agent: one conversation.
      if (!space || !agent || terminal["state"] !== "live") return [];
      const state = String(status?.["state"] ?? "unknown");
      const cwd = String(
        (terminal["foreground"] as Json | undefined)?.["cwd"] ?? terminal["cwd"] ?? "",
      );
      const session = labels[AGENT_SESSION];
      return [
        {
          paneId: String(terminal["address"]),
          tabId: labels["herdr.tab"] ?? "",
          workspaceId: space,
          agent,
          status: (["idle", "working", "blocked", "done"].includes(state)
            ? state
            : state === "error"
              ? "idle"
              : "unknown") as PaneAgent["status"],
          cwd,
          title: String(terminal["title"] ?? ""),
          workspace: spaces.find((s) => s.id === space)?.name || folderName(cwd),
          session: session ? { kind: "id", value: session } : null,
        },
      ];
    });
  }

  prompt(paneId: string, text: string): Promise<Json> {
    return this.core.call("terminal.send", { terminal: paneId, text });
  }

  sendKeys(paneId: string, keys: string[]): Promise<Json> {
    return this.core.call("terminal.keys", { terminal: paneId, keys });
  }

  sendText(paneId: string, text: string): Promise<Json> {
    const keys = [...text].map((c) => (c === " " ? "space" : c));
    return this.core.call("terminal.keys", { terminal: paneId, keys });
  }

  async screen(paneId: string): Promise<{ text: string; rows: number }> {
    const read = await this.core.call("terminal.read", { terminal: paneId, lines: 0 });
    const text = String(read["text"] ?? "");
    return { text, rows: text.split("\n").length };
  }

  async start(kind: string, cwd: string, args: string[] = []): Promise<string> {
    const labels: Record<string, string> = {
      [SPACE]: await this.spaceFor(cwd),
      [AGENT]: kind,
    };
    let argv = args;
    // A new conversation gets its id now, so its record is found at once.
    if (!args.length && PRESET_ID.has(kind)) {
      const id = randomUUID();
      argv = ["--session-id", id];
      labels[AGENT_SESSION] = id;
    }
    const resumed = args.indexOf("--resume") >= 0 ? args[args.indexOf("--resume") + 1] : undefined;
    const fixed =
      args.indexOf("--session-id") >= 0 ? args[args.indexOf("--session-id") + 1] : undefined;
    if (resumed ?? fixed) labels[AGENT_SESSION] = (resumed ?? fixed)!;
    const run = await this.core.call("terminal.run", {
      // A shell line: the agent may be a script shim (claude.cmd).
      line: [kind, ...argv].map(quote).join(" "),
      cwd,
      labels,
      keep: true,
      no_parent: true,
      outlive_parent: true,
      no_notify: true,
    });
    return String(run["address"] ?? (run["terminal"] as Json | undefined)?.["address"] ?? "");
  }

  /** The window's space for [cwd]: the one there, else one of its own. */
  private async spaceFor(cwd: string): Promise<string> {
    const found = (await this.spaceList(true)).find((s) => s.folder && sameFolder(s.folder, cwd));
    if (found) return found.id;
    // An id the window doesn't know becomes a space, named after the folder.
    return `baya-${createHash("sha256").update(cwd.toLowerCase()).digest("hex").slice(0, 12)}`;
  }

  /** The window's spaces, read at most every 10 s; none when it is closed. */
  private async spaceList(fresh = false): Promise<SpaceInfo[]> {
    if (!fresh && Date.now() - this.spaces.at < 10_000) return this.spaces.list;
    const list = await windowLs().catch(() => null);
    if (list) this.spaces = { at: Date.now(), list };
    return this.spaces.list;
  }
}

/** `herdr-app ls`: the open window's spaces. */
async function windowLs(): Promise<SpaceInfo[]> {
  const app =
    (await findExecutable("herdr-app")) ??
    (process.platform === "win32"
      ? join(
          process.env["LOCALAPPDATA"] ?? join(homedir(), "AppData", "Local"),
          "Programs",
          "herdr-app",
          "herdr-app.exe",
        )
      : null);
  if (!app) return [];
  const out = await new Promise<string>((resolve, reject) =>
    execFile(app, ["ls"], { timeout: 10_000, windowsHide: true }, (error, stdout) =>
      error ? reject(error) : resolve(`${stdout}`),
    ),
  );
  const parsed = JSON.parse(out) as Json;
  return ((parsed["spaces"] as Json[] | undefined) ?? []).map((space) => ({
    id: String(space["id"] ?? ""),
    name: String(space["name"] ?? ""),
    folder: String(space["folder"] ?? ""),
  }));
}

/**
 * Where this computer's agents live in panes: the herdr-app window on
 * Windows (herdr's server runs there with no window of its own), herdr's
 * server elsewhere.
 */
export const herdrWindow = new HerdrWindow();
