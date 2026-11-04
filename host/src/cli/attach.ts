/**
 * `baya attach`: a session of this computer's host in the terminal, live
 * alongside the phone. Both are clients of the same session, so what one
 * sends the other sees as it happens, and the agent has one conversation,
 * whichever agent it is.
 */
import { randomUUID } from "node:crypto";
import { connect, type Socket } from "node:net";
import { clearLine, createInterface, cursorTo, type Interface } from "node:readline";
import { isObject, type Json, JsonRpcPeer, type RpcId } from "../acp/jsonrpc.ts";
import { readControlInfo } from "../control/client.ts";
import { bold, cyan, dim, green, red, yellow } from "./ui.ts";

interface SessionInfo {
  sessionId: string;
  cwd: string;
  title: string;
  updatedAt: string;
  agentName: string;
  working: boolean;
}

function sessionInfo(raw: Json): SessionInfo {
  const baya = isObject(raw["_meta"]) && isObject(raw["_meta"]["baya"]) ? raw["_meta"]["baya"] : {};
  return {
    sessionId: String(raw["sessionId"]),
    cwd: String(raw["cwd"] ?? ""),
    title: String(raw["title"] ?? ""),
    updatedAt: String(raw["updatedAt"] ?? ""),
    agentName: String(baya["agentName"] ?? baya["agent"] ?? ""),
    working: baya["working"] === true,
  };
}

/** The session [query] names (id prefix or words of its title), or the latest. */
export function pickSession(sessions: SessionInfo[], query: string | undefined): SessionInfo {
  const sorted = [...sessions].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  if (!query) {
    const latest = sorted[0];
    if (!latest) throw new Error("No sessions yet. Start one: baya open <folder>");
    return latest;
  }
  const lower = query.toLowerCase();
  const matches = sorted.filter(
    (s) => s.sessionId.startsWith(query) || s.title.toLowerCase().includes(lower),
  );
  if (matches.length === 0) throw new Error(`No session matches "${query}". See: baya status`);
  return matches[0]!;
}

/** The control socket in attach mode, as JSON-RPC lines. */
async function openSocket(): Promise<{
  socket: Socket;
  lines: (on: (line: string) => void) => void;
}> {
  const info = readControlInfo();
  if (!info) throw new Error("Baya is not running. Start it with `baya start`.");
  const socket = connect({ host: "127.0.0.1", port: info.port });
  socket.setEncoding("utf8");
  let buffer = "";
  let handler: ((line: string) => void) | null = null;
  const queue: string[] = [];
  socket.on("data", (chunk: string) => {
    buffer += chunk;
    for (let n = buffer.indexOf("\n"); n >= 0; n = buffer.indexOf("\n")) {
      const line = buffer.slice(0, n);
      buffer = buffer.slice(n + 1);
      if (handler) handler(line);
      else queue.push(line);
    }
  });
  await new Promise<void>((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  socket.write(`${JSON.stringify({ token: info.token, id: randomUUID(), command: "attach" })}\n`);
  const first = await new Promise<string>((resolve, reject) => {
    handler = (line) => {
      handler = null;
      resolve(line);
    };
    socket.once("close", () => reject(new Error("Baya closed the connection.")));
  });
  const reply = JSON.parse(first) as { ok?: boolean; error?: string };
  if (!reply.ok) throw new Error(reply.error ?? "Baya refused to attach.");
  return {
    socket,
    lines: (on) => {
      handler = on;
      for (const line of queue.splice(0)) on(line);
    },
  };
}

/** Prints above the input line, keeping what is being typed. */
class Screen {
  /** Agent text not yet ended by a newline. */
  private partial = "";
  private block: string | null = null;
  rl: Interface | null = null;

  line(text: string): void {
    this.flush();
    this.write(`${text}\n`);
  }

  /** Streamed agent text: whole lines show as they complete. */
  agent(text: string): void {
    this.enter("agent");
    this.partial += text;
    const end = this.partial.lastIndexOf("\n");
    if (end < 0) return;
    this.write(this.partial.slice(0, end + 1));
    this.partial = this.partial.slice(end + 1);
  }

  /** A new kind of output starts; the last one's text is ended. */
  enter(block: string): boolean {
    if (this.block === block) return false;
    this.flush();
    this.block = block;
    return true;
  }

  flush(): void {
    if (this.partial) {
      const rest = this.partial;
      this.partial = "";
      this.write(`${rest}\n`);
    }
    this.block = null;
  }

  private write(text: string): void {
    const rl = this.rl;
    if (rl && process.stdout.isTTY) {
      clearLine(process.stdout, 0);
      cursorTo(process.stdout, 0);
    }
    process.stdout.write(text);
    if (rl && process.stdout.isTTY) rl.prompt(true);
  }
}

export async function attach(query: string | undefined): Promise<void> {
  const { socket, lines } = await openSocket();
  const screen = new Screen();
  let sessionId = "";
  let working = false;
  let user: string | null = null;
  const tools = new Map<string, string>();
  /** A permission question waiting for a number typed. */
  let question: {
    id: RpcId;
    options: Array<{ optionId: string; name: string }>;
    answer: (result: Json) => void;
  } | null = null;

  const update = (raw: Json) => {
    const kind = raw["sessionUpdate"];
    const content = isObject(raw["content"]) ? raw["content"] : {};
    const text = typeof content["text"] === "string" ? content["text"] : "";
    switch (kind) {
      case "user_message_chunk": {
        const id = String(raw["messageId"] ?? "");
        if (screen.enter(`user:${id}`) || user !== id) {
          user = id;
          screen.line(`${cyan("›")} ${bold(text)}`);
        }
        return;
      }
      case "agent_message_chunk":
        screen.agent(text);
        return;
      case "agent_thought_chunk":
        if (screen.enter("thought")) screen.line(dim("· thinking…"));
        return;
      case "tool_call": {
        const id = String(raw["toolCallId"]);
        const title = String(raw["title"] ?? "tool");
        tools.set(id, title);
        screen.enter(`tool:${id}`);
        screen.line(dim(`⚙ ${title}`));
        return;
      }
      case "tool_call_update": {
        const status = raw["status"];
        const title = tools.get(String(raw["toolCallId"])) ?? String(raw["title"] ?? "tool");
        if (status === "completed") screen.line(dim(`  ${green("✓")} ${title}`));
        if (status === "failed") screen.line(`  ${red("✗")} ${title}`);
        return;
      }
      case "plan": {
        const entries = Array.isArray(raw["entries"]) ? raw["entries"] : [];
        screen.line(dim("Plan:"));
        for (const entry of entries) {
          if (!isObject(entry)) continue;
          const done = entry["status"] === "completed" ? green("✓") : dim("○");
          screen.line(`  ${done} ${String(entry["content"] ?? "")}`);
        }
        return;
      }
    }
  };

  const peer = new JsonRpcPeer({
    write: (message) => {
      if (!socket.destroyed) socket.write(`${JSON.stringify(message)}\n`);
    },
    onRequest: async (method, params, id) => {
      if (method === "session/request_permission") {
        const call = isObject(params["toolCall"]) ? params["toolCall"] : {};
        const options = (Array.isArray(params["options"]) ? params["options"] : [])
          .filter(isObject)
          .map((o) => ({ optionId: String(o["optionId"]), name: String(o["name"]) }));
        screen.line(yellow(`? ${String(call["title"] ?? "The agent asks for permission")}`));
        for (const [i, o] of options.entries()) {
          screen.line(`  ${bold(String(i + 1))}. ${o.name}`);
        }
        screen.line(dim("  Type a number (or answer on the phone)."));
        return new Promise((answer) => {
          question = { id, options, answer };
        });
      }
      if (method === "elicitation/create") {
        screen.line(yellow("? The agent asks for details. Answer it on the phone."));
        return new Promise(() => {});
      }
      throw new Error(`Not handled here: ${method}`);
    },
    onNotification: (method, params) => {
      if (method === "session/update" && params["sessionId"] === sessionId) {
        if (isObject(params["update"])) update(params["update"]);
      } else if (method === "_baya/session_changed" && isObject(params["session"])) {
        const info = sessionInfo(params["session"]);
        if (info.sessionId !== sessionId) return;
        if (working && !info.working) screen.flush();
        working = info.working;
      } else if (method === "$/cancel_request" && question && params["requestId"] === question.id) {
        question.answer({ outcome: { outcome: "cancelled" } });
        question = null;
        screen.line(dim("  Answered elsewhere."));
      }
    },
  });
  lines((line) => {
    try {
      peer.receive(JSON.parse(line));
    } catch {
      // Not ours to read.
    }
  });

  await peer.request("initialize", {
    protocolVersion: 1,
    clientCapabilities: {},
    clientInfo: { name: "baya-attach", title: "Baya terminal" },
  });
  const listed = await peer.request<{ sessions?: Json[] }>("session/list", {});
  const session = pickSession((listed.sessions ?? []).map(sessionInfo), query);
  sessionId = session.sessionId;
  process.stdout.write(
    `${bold(session.title || session.cwd)} ${dim(`· ${session.agentName} · ${session.cwd}`)}\n${dim(
      "Live with the phone. Enter sends; Ctrl+C stops the turn, twice quits.",
    )}\n\n`,
  );
  // The history replays as updates before the answer.
  await peer.request("session/load", { sessionId, cwd: session.cwd, mcpServers: [] });
  screen.flush();
  working = session.working;

  const rl = createInterface({ input: process.stdin, output: process.stdout, prompt: "› " });
  screen.rl = rl;
  if (process.stdout.isTTY) rl.prompt();
  let lastInterrupt = 0;
  await new Promise<void>((resolve) => {
    // Closing the socket detaches this terminal from the session.
    let closed = false;
    const quit = () => {
      if (closed) return;
      closed = true;
      screen.rl = null;
      rl.close();
      socket.end();
      resolve();
    };
    rl.on("line", (input) => {
      // The host echoes it back like any client's message.
      if (process.stdout.isTTY) process.stdout.write("\x1b[1A\x1b[2K");
      const text = input.trim();
      const open = question;
      if (open) {
        const choice = open.options[Number(text) - 1];
        if (!choice) {
          screen.line(dim(`  Type 1–${open.options.length}.`));
          return;
        }
        open.answer({ outcome: { outcome: "selected", optionId: choice.optionId } });
        question = null;
        screen.line(dim(`  → ${choice.name}`));
        return;
      }
      if (!text) return process.stdout.isTTY ? rl.prompt() : undefined;
      if (text === "/quit" || text === "/exit") return quit();
      working = true;
      peer
        .request("session/prompt", {
          sessionId,
          prompt: [{ type: "text", text }],
          _meta: { baya: { messageId: randomUUID() } },
        })
        .then(
          () => screen.flush(),
          (error: Error) => screen.line(red(`✗ ${error.message}`)),
        );
    });
    rl.on("SIGINT", () => {
      const now = Date.now();
      if (working && now - lastInterrupt > 2000) {
        peer.notify("session/cancel", { sessionId });
        screen.line(dim("Stopping the turn… (Ctrl+C again to quit)"));
        lastInterrupt = now;
        return;
      }
      if (now - lastInterrupt < 2000 || !working) return quit();
    });
    rl.on("close", () => {
      closed = true;
      screen.rl = null;
      socket.end();
      resolve();
    });
    socket.on("close", () => {
      if (closed) return;
      screen.rl = null;
      screen.line(dim("Baya closed the connection."));
      quit();
    });
  });
}
