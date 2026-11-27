/**
 * The herdr app's server: its workspaces, tabs and panes, and the coding
 * agents it recognizes in them. Baya speaks its socket API (one JSON
 * request and one JSON reply per line), the same one the `herdr` CLI uses.
 */
import { execFile } from "node:child_process";
import { connect } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Json } from "../acp/jsonrpc.ts";

export class HerdrAppError extends Error {
  readonly code: string | undefined;
  constructor(message: string, code?: string) {
    super(message);
    this.code = code;
  }
}

/** One agent in a pane, as herdr reports it. */
export interface PaneAgent {
  paneId: string;
  tabId: string;
  workspaceId: string;
  agent: string;
  status: "idle" | "working" | "blocked" | "done" | "unknown";
  cwd: string;
  title: string;
  /** The herdr workspace it sits in, by name. */
  workspace: string;
  /** The agent's own session, when its integration reported it. */
  session: { kind: "id" | "path"; value: string } | null;
}

/**
 * Where agents run in panes on this computer: herdr's server (its TUI), or
 * the herdr-app window over herdr-core. One conversation per pane.
 */
export interface PaneHost {
  available(): Promise<boolean>;
  agents(): Promise<PaneAgent[]>;
  /** Types [text] into the agent in [paneId] and presses Enter. */
  prompt(paneId: string, text: string): Promise<unknown>;
  sendKeys(paneId: string, keys: string[]): Promise<unknown>;
  /** Types [text] without pressing Enter. */
  sendText(paneId: string, text: string): Promise<unknown>;
  screen(paneId: string): Promise<{ text: string; rows: number }>;
  /** A new tab in [cwd]'s workspace running [kind] with [args]: its pane. */
  start(kind: string, cwd: string, args?: string[], label?: string): Promise<string>;
  /** Integrations that make panes report their agent's session. */
  prepare(): Promise<void>;
}

/** Where herdr's server listens on this computer. */
export function herdrSocketPath(): string {
  const override = process.env["HERDR_SOCKET_PATH"];
  if (override) return override;
  if (process.platform === "win32") {
    return join(
      process.env["APPDATA"] ?? join(homedir(), "AppData", "Roaming"),
      "herdr",
      "herdr.sock",
    );
  }
  if (process.platform === "darwin") {
    return join(homedir(), "Library", "Application Support", "herdr", "herdr.sock");
  }
  return join(process.env["XDG_CONFIG_HOME"] ?? join(homedir(), ".config"), "herdr", "herdr.sock");
}

let next = 0;

export class HerdrApp implements PaneHost {
  private readonly path: () => string;

  constructor(path: () => string = herdrSocketPath) {
    this.path = path;
  }

  /** One request on its own connection: its result, or why not. */
  call(method: string, params: Json = {}, timeoutMs = 15_000): Promise<Json> {
    // On Windows herdr listens on an AF_UNIX socket, which Node cannot open
    // (it takes the path for a named pipe): its own CLI makes the call.
    if (process.platform === "win32") return viaCli(method, params, timeoutMs);
    return new Promise((resolve, reject) => {
      const id = `baya-${++next}`;
      const socket = connect(this.path());
      let buffer = "";
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new HerdrAppError(`herdr did not answer ${method}.`, "timeout"));
      }, timeoutMs);
      const done = (fn: () => void) => {
        clearTimeout(timer);
        socket.destroy();
        fn();
      };
      socket.setEncoding("utf8");
      socket.on("connect", () => socket.write(`${JSON.stringify({ id, method, params })}\n`));
      socket.on("data", (chunk: string) => {
        buffer += chunk;
        let newline = buffer.indexOf("\n");
        while (newline >= 0) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          newline = buffer.indexOf("\n");
          let reply: Json;
          try {
            reply = JSON.parse(line) as Json;
          } catch {
            continue;
          }
          if (reply["id"] !== id) continue;
          const error = reply["error"] as Json | undefined;
          if (error) {
            return done(() =>
              reject(
                new HerdrAppError(String(error["message"] ?? method), String(error["code"] ?? "")),
              ),
            );
          }
          return done(() => resolve((reply["result"] as Json) ?? {}));
        }
      });
      socket.on("error", (error) =>
        done(() =>
          reject(new HerdrAppError(`herdr is not running (${error.message}).`, "unavailable")),
        ),
      );
    });
  }

  async available(): Promise<boolean> {
    try {
      await this.call("agent.list", {}, 3_000);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * herdr's integrations for the agents Baya reads (hooks that tell herdr
   * which conversation each pane holds), installed once where missing.
   */
  async prepare(): Promise<void> {
    const list = await this.call("integration.list", {});
    const integrations = (list["integrations"] as Json[] | undefined) ?? [];
    for (const target of ["claude", "codex", "pi"]) {
      const entry = integrations.find((i) => i["target"] === target);
      // Not listed (the CLI on Windows lists none): install anyway, it is
      // idempotent; listed: only where the agent is there and it is missing.
      if (entry && (entry["available"] !== true || entry["state"] !== "not_installed")) continue;
      await this.call("integration.install", { target }).catch(() => {});
    }
  }

  /** Every pane with a recognized agent, and its session where known. */
  async agents(): Promise<PaneAgent[]> {
    return (await this.list()).agents;
  }

  /** Every pane's id, and the agents among them. */
  async list(): Promise<{ ids: Set<string>; agents: PaneAgent[] }> {
    const result = await this.call("pane.list", {});
    const panes = (result["panes"] as Json[] | undefined) ?? [];
    const ids = new Set(panes.map((pane) => String(pane["pane_id"])));
    const spaces = await this.call("workspace.list", {}).catch(() => ({}) as Json);
    const label = new Map(
      ((spaces["workspaces"] as Json[] | undefined) ?? []).map((w) => [
        String(w["workspace_id"]),
        String(w["label"] ?? ""),
      ]),
    );
    const agents = panes.flatMap((pane): PaneAgent[] => {
      const agent = pane["agent"];
      if (typeof agent !== "string" || !agent) return [];
      const session = pane["agent_session"] as Json | null | undefined;
      return [
        {
          paneId: String(pane["pane_id"]),
          tabId: String(pane["tab_id"]),
          workspaceId: String(pane["workspace_id"]),
          agent,
          status: (pane["agent_status"] as PaneAgent["status"]) ?? "unknown",
          cwd: String(pane["foreground_cwd"] ?? pane["cwd"] ?? ""),
          title: String(pane["terminal_title_stripped"] ?? ""),
          workspace: label.get(String(pane["workspace_id"])) ?? "",
          session:
            session && (session["kind"] === "id" || session["kind"] === "path")
              ? { kind: session["kind"], value: String(session["value"]) }
              : null,
        },
      ];
    });
    return { ids, agents };
  }

  /** Types [text] into the agent in [paneId] and presses Enter. */
  prompt(paneId: string, text: string): Promise<Json> {
    return this.call("agent.prompt", { target: paneId, text });
  }

  sendKeys(paneId: string, keys: string[]): Promise<Json> {
    return this.call("pane.send_keys", { pane_id: paneId, keys });
  }

  sendText(paneId: string, text: string): Promise<Json> {
    return this.call("pane.send_text", { pane_id: paneId, text });
  }

  /** What [paneId] shows now, with its colours, and how many rows it has. */
  async screen(paneId: string): Promise<{ text: string; rows: number }> {
    const read = await this.call("pane.read", {
      pane_id: paneId,
      source: "visible",
      format: "ansi",
      strip_ansi: false,
    });
    const text = String((read["read"] as Json | undefined)?.["text"] ?? "");
    return { text, rows: text.split("\n").length };
  }

  /**
   * A tab in [cwd]'s workspace showing herdr-core's terminal [terminal]
   * (`hc attach`): an agent that runs in the herdr-app window, seen and
   * typed into here too. Its pane.
   */
  async openMirror(cwd: string, terminal: string, label: string): Promise<string> {
    const pane = await this.tabFor(cwd, label);
    await this.call("pane.send_text", { pane_id: pane, text: `hc attach ${terminal}` });
    await this.call("pane.send_keys", { pane_id: pane, keys: ["enter"] });
    return pane;
  }

  /** Tells herdr [paneId] holds [agent] in [state], as an integration would. */
  reportAgent(paneId: string, agent: string, state: string, sessionId?: string): Promise<Json> {
    return this.call("pane.report_agent", {
      pane_id: paneId,
      source: "baya",
      agent,
      state,
      seq: Date.now(),
      ...(sessionId ? { agent_session_id: sessionId } : {}),
    });
  }

  closePane(paneId: string): Promise<Json> {
    return this.call("pane.close", { pane_id: paneId });
  }

  /**
   * A fresh pane for [cwd]: a new tab in its folder's workspace, or the
   * first tab of a workspace made for it (no empty shell left beside it).
   */
  private async tabFor(cwd: string, label?: string): Promise<string> {
    // Workspaces don't say their folder; their panes do.
    const list = await this.call("pane.list", {});
    const panes = (list["panes"] as Json[] | undefined) ?? [];
    const norm = (p: unknown) =>
      String(p ?? "")
        .replace(/[\\/]+$/u, "")
        .toLowerCase();
    const found = panes.find((p) => norm(p["cwd"]) === norm(cwd));
    if (!found) {
      const made = await this.call("workspace.create", { cwd, focus: false });
      return String((made["root_pane"] as Json)["pane_id"]);
    }
    const tab = await this.call("tab.create", {
      workspace_id: String(found["workspace_id"]),
      cwd,
      focus: false,
      ...(label ? { label } : {}),
    });
    return String((tab["root_pane"] as Json)["pane_id"]);
  }

  /**
   * A new tab in [cwd]'s workspace with [kind] (claude, codex, pi...)
   * started in it, [args] passed to the agent. Its pane.
   */
  async start(kind: string, cwd: string, args: string[] = [], label?: string): Promise<string> {
    const pane = await this.tabFor(cwd, label);
    await this.call(
      "agent.start",
      { name: `baya-${pane.replace(/[^a-z0-9]/giu, "").toLowerCase()}`, kind, pane_id: pane, args },
      60_000,
    ).catch((error: unknown) => {
      // Ready or not (a trust prompt, a login), the agent is in the pane.
      if (error instanceof HerdrAppError && error.code === "agent_not_ready") return {};
      throw error;
    });
    return pane;
  }
}

export const herdrApp = new HerdrApp();

/** The `herdr` command line for an API method, where it has one. */
function cliArgs(method: string, params: Json): string[] {
  const str = (key: string) => String(params[key] ?? "");
  switch (method) {
    case "pane.list":
      return ["pane", "list"];
    case "agent.list":
      return ["agent", "list"];
    case "agent.prompt":
      return ["agent", "prompt", str("target"), str("text")];
    case "pane.send_keys":
      return ["pane", "send-keys", str("pane_id"), ...((params["keys"] as string[]) ?? [])];
    case "workspace.list":
      return ["workspace", "list"];
    case "workspace.create":
      return ["workspace", "create", "--cwd", str("cwd"), "--no-focus"];
    case "tab.create":
      return [
        "tab",
        "create",
        "--workspace",
        str("workspace_id"),
        "--cwd",
        str("cwd"),
        "--no-focus",
        ...(params["label"] ? ["--label", str("label")] : []),
      ];
    case "agent.start":
      return [
        "agent",
        "start",
        str("name"),
        "--kind",
        str("kind"),
        "--pane",
        str("pane_id"),
        ...(((params["args"] as string[]) ?? []).length
          ? ["--", ...(params["args"] as string[])]
          : []),
      ];
    case "integration.install":
      return ["integration", "install", str("target")];
    case "pane.send_text":
      return ["pane", "send-text", str("pane_id"), str("text")];
    case "pane.report_agent":
      return [
        "pane",
        "report-agent",
        "--source",
        str("source"),
        "--agent",
        str("agent"),
        "--state",
        str("state"),
        "--seq",
        str("seq"),
        ...(params["agent_session_id"] ? ["--agent-session-id", str("agent_session_id")] : []),
        str("pane_id"),
      ];
    case "pane.close":
      return ["pane", "close", str("pane_id")];
    case "pane.read":
      return ["pane", "read", str("pane_id"), "--source", "visible", "--ansi"];
    default:
      throw new HerdrAppError(`herdr's CLI has no ${method}.`, "unsupported");
  }
}

function viaCli(method: string, params: Json, timeoutMs: number): Promise<Json> {
  // The list of integrations comes as text from the CLI: installing the
  // three Baya reads is idempotent, so the list is left empty here.
  if (method === "integration.list") return Promise.resolve({ integrations: [] });
  return new Promise((resolve, reject) => {
    execFile(
      "herdr",
      cliArgs(method, params),
      { timeout: timeoutMs, windowsHide: true, maxBuffer: 16 * 1024 * 1024 },
      (error, stdout, stderr) => {
        const text = `${stdout}`.trim() || `${stderr}`.trim();
        let reply: Json | null = null;
        try {
          reply = JSON.parse(text.split("\n").find((l) => l.startsWith("{")) ?? "") as Json;
        } catch {
          reply = null;
        }
        const failure = reply?.["error"] as Json | undefined;
        if (failure) {
          return reject(
            new HerdrAppError(String(failure["message"] ?? method), String(failure["code"] ?? "")),
          );
        }
        if (reply && "result" in reply) return resolve((reply["result"] as Json) ?? {});
        // `pane read` prints the screen itself.
        if (!error && method === "pane.read") return resolve({ read: { text: `${stdout}` } });
        if (error)
          return reject(
            new HerdrAppError(`herdr is not running (${error.message}).`, "unavailable"),
          );
        resolve({});
      },
    );
  });
}
