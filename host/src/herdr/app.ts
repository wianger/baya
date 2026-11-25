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
  /** The agent's own session, when its integration reported it. */
  session: { kind: "id" | "path"; value: string } | null;
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

export class HerdrApp {
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

  /** Every pane with a recognized agent, and its session where known. */
  async agents(): Promise<PaneAgent[]> {
    const result = await this.call("pane.list", {});
    const panes = (result["panes"] as Json[] | undefined) ?? [];
    return panes.flatMap((pane) => {
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
          session:
            session && (session["kind"] === "id" || session["kind"] === "path")
              ? { kind: session["kind"], value: String(session["value"]) }
              : null,
        },
      ];
    });
  }

  /** Types [text] into the agent in [paneId] and presses Enter. */
  prompt(paneId: string, text: string): Promise<Json> {
    return this.call("agent.prompt", { target: paneId, text });
  }

  sendKeys(paneId: string, keys: string[]): Promise<Json> {
    return this.call("pane.send_keys", { pane_id: paneId, keys });
  }

  /** The workspace for [cwd], made when there is none. */
  async workspaceFor(cwd: string): Promise<string> {
    const list = await this.call("workspace.list", {});
    const workspaces = (list["workspaces"] as Json[] | undefined) ?? [];
    const norm = (p: unknown) => String(p ?? "").replace(/[\\/]+$/u, "");
    const found = workspaces.find((w) => norm(w["cwd"]) === norm(cwd));
    if (found) return String(found["workspace_id"]);
    const made = await this.call("workspace.create", { cwd, focus: false });
    return String((made["workspace"] as Json)["workspace_id"]);
  }

  /**
   * A new tab in [cwd]'s workspace with [kind] (claude, codex, pi...)
   * started in it, [args] passed to the agent. Its pane.
   */
  async start(kind: string, cwd: string, args: string[] = [], label?: string): Promise<string> {
    const workspace = await this.workspaceFor(cwd);
    const tab = await this.call("tab.create", {
      workspace_id: workspace,
      cwd,
      focus: false,
      ...(label ? { label } : {}),
    });
    const pane = String((tab["root_pane"] as Json)["pane_id"]);
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
        if (error)
          return reject(
            new HerdrAppError(`herdr is not running (${error.message}).`, "unavailable"),
          );
        resolve({});
      },
    );
  });
}
