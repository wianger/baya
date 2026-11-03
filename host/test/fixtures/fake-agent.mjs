// A scripted ACP v1 agent for tests. It supports `session/resume` (not
// `session/load`), streams a reply, runs one tool, and asks permission when
// the prompt says "ask".
import { createInterface } from "node:readline";

let sequence = 0;
const waiting = new Map();
const sessions = new Set();
let cancelled = null;

const write = (message) =>
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
const notify = (method, params) => write({ method, params });
const request = (method, params) =>
  new Promise((resolve) => {
    const id = `agent-${++sequence}`;
    waiting.set(id, resolve);
    write({ id, method, params });
  });
const update = (sessionId, update) => notify("session/update", { sessionId, update });

const config = [
  {
    id: "model",
    name: "Model",
    category: "model",
    type: "select",
    currentValue: "fast",
    options: [
      { value: "fast", name: "Fast" },
      { value: "smart", name: "Smart" },
    ],
  },
];

async function handle(method, params) {
  switch (method) {
    case "initialize":
      return {
        protocolVersion: 1,
        agentInfo: { name: "fake", version: "1.0.0" },
        agentCapabilities: {
          loadSession: false,
          promptCapabilities: { image: false },
          sessionCapabilities: { resume: {} },
        },
        authMethods: [],
      };
    case "session/new": {
      const sessionId = `fake-${sessions.size + 1}`;
      sessions.add(sessionId);
      setTimeout(() =>
        update(sessionId, {
          sessionUpdate: "available_commands_update",
          availableCommands: [{ name: "compact", description: "Compact the context" }],
        }),
      );
      return { sessionId, configOptions: config };
    }
    case "session/resume":
      if (!sessions.has(params.sessionId) && !process.env.FAKE_AGENT_RESUMES) {
        throw Object.assign(new Error("unknown session"), { code: -32002 });
      }
      sessions.add(params.sessionId);
      return { configOptions: config };
    case "session/set_config_option":
      config[0].currentValue = params.value;
      return { configOptions: config };
    case "session/prompt": {
      const text = params.prompt.map((block) => block.text ?? "").join("");
      const id = params.sessionId;
      if (text === "exit") process.exit(3);
      update(id, {
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text: "Thinking" },
      });
      update(id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "Hello " },
      });
      update(id, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "world" },
      });
      update(id, {
        sessionUpdate: "tool_call",
        toolCallId: "t1",
        title: "Read file",
        kind: "read",
        status: "pending",
      });
      if (text.includes("ask")) {
        const answer = await request("session/request_permission", {
          sessionId: id,
          toolCall: { toolCallId: "t1" },
          options: [
            { optionId: "yes", name: "Allow", kind: "allow_once" },
            { optionId: "no", name: "Reject", kind: "reject_once" },
          ],
        });
        update(id, {
          sessionUpdate: "agent_message_chunk",
          content: {
            type: "text",
            text: ` (${answer.outcome.outcome}:${answer.outcome.optionId ?? "-"})`,
          },
        });
      }
      if (text.includes("wait")) {
        await new Promise((resolve) => {
          cancelled = resolve;
        });
        return { stopReason: "cancelled" };
      }
      update(id, { sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed" });
      update(id, { sessionUpdate: "usage_update", used: 1200, size: 200000 });
      return { stopReason: "end_turn" };
    }
    default:
      throw Object.assign(new Error(`Method not found: ${method}`), { code: -32601 });
  }
}

createInterface({ input: process.stdin }).on("line", async (line) => {
  if (!line.trim()) return;
  const message = JSON.parse(line);
  if (message.method === "session/cancel") {
    cancelled?.();
    cancelled = null;
    return;
  }
  if (message.method && message.id !== undefined) {
    try {
      write({ id: message.id, result: await handle(message.method, message.params ?? {}) });
    } catch (error) {
      write({ id: message.id, error: { code: error.code ?? -32603, message: error.message } });
    }
    return;
  }
  if (message.id !== undefined && waiting.has(message.id)) {
    waiting.get(message.id)(message.result);
    waiting.delete(message.id);
  }
});
