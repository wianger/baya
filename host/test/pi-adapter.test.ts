import { describe, expect, test } from "vitest";
import {
  PiAdapter,
  type PiRpcPort,
  piExtensionUiResponse,
  piHistoryEvents,
  piSpawnArgs,
} from "../src/adapters/pi.ts";
import type { ServerMessage } from "../src/protocol/types.ts";
import type { PeerChannel } from "../src/transport/peer_channel.ts";

class FakeRpc implements PiRpcPort {
  readonly requests: Array<{ type: string; payload?: Record<string, unknown> }> = [];
  readonly writes: Record<string, unknown>[] = [];

  async start(): Promise<void> {}
  close(): void {}

  async request(type: string, payload?: Record<string, unknown>): Promise<unknown> {
    this.requests.push({ type, ...(payload ? { payload } : {}) });
    if (type === "get_state") {
      return {
        sessionId: "native-session",
        model: { id: "test-model", name: "Test Model", provider: "test" },
      };
    }
    if (type === "prompt") return { disposition: "started" };
    return {};
  }

  write(payload: Record<string, unknown>): void {
    this.writes.push(payload);
  }
}

function sender(sent: ServerMessage[] = []): PeerChannel {
  return {
    remotePeerId: "device",
    send(message) {
      sent.push(message);
    },
  };
}

describe("Pi standalone RPC adapter", () => {
  test("spawns Pi in RPC mode without injecting an extension", () => {
    const args = piSpawnArgs({
      cwd: "C:\\work",
      name: "Review",
      sessionId: "session",
    });
    expect(args).toEqual([
      "--mode",
      "rpc",
      "--approve",
      "--session-id",
      "session",
      "--name",
      "Review",
    ]);
    expect(args).not.toContain("--extension");
    expect(args).not.toContain("-e");
  });

  test("emits agent_done once at agent_settled, not at each assistant message", async () => {
    const broadcast: ServerMessage[] = [];
    const busy: boolean[] = [];
    const adapter = new PiAdapter(
      {
        cwd: "C:\\work",
        name: "Review",
        sessionId: "baya-session",
        broadcast: (message) => broadcast.push(message),
        onBusy: (value) => busy.push(value),
      },
      new FakeRpc(),
    );
    await adapter.start();

    adapter.receiveEvent({ type: "agent_start" });
    adapter.receiveEvent({
      type: "message_start",
      message: { role: "assistant", content: [] },
    });
    adapter.receiveEvent({
      type: "message_update",
      assistantMessageEvent: {
        type: "text_delta",
        contentIndex: 0,
        delta: "Checking ",
      },
    });
    adapter.receiveEvent({
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "Checking " }],
        usage: { input: 12, output: 3 },
      },
    });
    expect(broadcast.some((message) => message.type === "agent_done")).toBe(false);

    adapter.receiveEvent({
      type: "message_start",
      message: { role: "assistant", content: [] },
    });
    adapter.receiveEvent({
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "Done." }],
        usage: { input: 20, output: 6 },
      },
    });
    adapter.receiveEvent({ type: "agent_settled", aborted: false });

    const done = broadcast.filter((message) => message.type === "agent_done");
    expect(done).toEqual([
      {
        type: "agent_done",
        in_reply_to: "pi",
        usage: { input_tokens: 20, output_tokens: 6 },
      },
    ]);
    expect(busy).toEqual([true, false]);
  });

  test("translates extension responses to Pi's discriminated RPC shape", async () => {
    expect(
      piExtensionUiResponse({
        type: "extension_ui_response",
        id: "confirm",
        confirmed: false,
      }),
    ).toEqual({
      type: "extension_ui_response",
      id: "confirm",
      confirmed: false,
    });
    expect(
      piExtensionUiResponse({
        type: "extension_ui_response",
        id: "select",
        value: "Allow",
      }),
    ).toEqual({
      type: "extension_ui_response",
      id: "select",
      value: "Allow",
    });
    expect(
      piExtensionUiResponse({
        type: "extension_ui_response",
        id: "cancel",
        cancelled: true,
      }),
    ).toEqual({
      type: "extension_ui_response",
      id: "cancel",
      cancelled: true,
    });

    const rpc = new FakeRpc();
    const sent: ServerMessage[] = [];
    const adapter = new PiAdapter(
      {
        cwd: "C:\\work",
        name: "Review",
        sessionId: "baya-session",
        broadcast: () => {},
      },
      rpc,
    );
    await adapter.handle(sender(sent), {
      type: "extension_ui_response",
      id: "ask",
      confirmed: true,
    });
    expect(rpc.writes).toEqual([
      {
        type: "extension_ui_response",
        id: "ask",
        confirmed: true,
      },
    ]);
  });

  test("a rejected prompt ends the turn on every phone", async () => {
    const rpc = new FakeRpc();
    rpc.request = async (type) => {
      if (type === "prompt") throw new Error("model unavailable");
      return {};
    };
    const broadcast: ServerMessage[] = [];
    const sent: ServerMessage[] = [];
    const adapter = new PiAdapter(
      {
        cwd: "C:\\work",
        name: "Review",
        sessionId: "baya-session",
        broadcast: (message) => broadcast.push(message),
      },
      rpc,
    );
    await adapter.handle(sender(sent), { type: "user_message", id: "u1", text: "hi" });
    expect(sent).toEqual([]);
    expect(broadcast.map((message) => message.type)).toEqual(["user_message", "error"]);
    expect(broadcast[1]).toMatchObject({ in_reply_to: "u1", message: "model unavailable" });
  });

  test("rejects a synthetic approve_tool prompt", async () => {
    const rpc = new FakeRpc();
    const sent: ServerMessage[] = [];
    const adapter = new PiAdapter(
      {
        cwd: "C:\\work",
        name: "Review",
        sessionId: "baya-session",
        broadcast: () => {},
      },
      rpc,
    );
    await adapter.handle(sender(sent), {
      type: "approve_tool",
      id: "approve",
      tool_call_id: "tool",
      decision: "allow",
    });
    expect(rpc.requests).toEqual([]);
    expect(sent).toEqual([
      {
        type: "error",
        code: "unsupported_type",
        in_reply_to: "approve",
        message: "Pi RPC handles tool approval through its native extension prompt.",
      },
    ]);
  });

  test("history preserves text and tool order and formats result content", () => {
    const events = piHistoryEvents(
      [
        {
          role: "user",
          timestamp: 1,
          content: [{ type: "text", text: "Inspect the file." }],
        },
        {
          role: "assistant",
          timestamp: 2,
          usage: { input: 8, output: 2 },
          content: [
            { type: "thinking", thinking: "Find the file." },
            { type: "text", text: "I will inspect it." },
            { type: "toolCall", id: "tool-1", name: "read", arguments: { path: "a.ts" } },
            { type: "text", text: "The file is valid." },
          ],
        },
        {
          role: "toolResult",
          toolCallId: "tool-1",
          content: [{ type: "text", text: "file contents" }],
        },
      ],
      () => 99,
    );

    expect(events.map((event) => event.type)).toEqual([
      "user_input",
      "agent_thinking",
      "agent_message",
      "tool_request",
      "agent_message",
      "tool_result",
    ]);
    expect(events.at(-1)).toMatchObject({
      type: "tool_result",
      tool_call_id: "tool-1",
      result: "file contents",
    });
  });
});
