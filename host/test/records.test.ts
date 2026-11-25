import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { agentFamily, claudeFolder, readRecord } from "../src/herdr/records.ts";

function record(lines: object[]): string {
  const path = join(mkdtempSync(join(tmpdir(), "baya-records-")), "r.jsonl");
  writeFileSync(path, `${lines.map((l) => JSON.stringify(l)).join("\n")}\n`);
  return path;
}

const kinds = (updates: Record<string, unknown>[]) => updates.map((u) => u["sessionUpdate"]);

describe("an agent's own record, read as the chat", () => {
  it("Claude Code: the live branch, its title, tools with their results", () => {
    const path = record([
      { type: "ai-title", aiTitle: "Fix the login" },
      { type: "user", uuid: "u1", parentUuid: null, message: { role: "user", content: "fix it" } },
      { type: "attachment", uuid: "a1", parentUuid: "u1" },
      {
        type: "assistant",
        uuid: "m1",
        parentUuid: "a1",
        message: {
          id: "msg1",
          role: "assistant",
          content: [
            { type: "text", text: "Looking." },
            { type: "tool_use", id: "t1", name: "Bash", input: { command: "ls src" } },
          ],
        },
      },
      {
        type: "user",
        uuid: "r1",
        parentUuid: "m1",
        message: {
          role: "user",
          content: [{ type: "tool_result", tool_use_id: "t1", content: "a.ts" }],
        },
      },
      // A rewound branch: not on the live path.
      { type: "user", uuid: "x1", parentUuid: "u1", message: { role: "user", content: "old try" } },
      { type: "user", uuid: "u2", parentUuid: "r1", message: { role: "user", content: "thanks" } },
    ]);
    const { updates, title } = readRecord("claude-code", path);
    expect(title).toBe("Fix the login");
    expect(kinds(updates)).toEqual([
      "user_message_chunk",
      "agent_message_chunk",
      "tool_call",
      "tool_call_update",
      "user_message_chunk",
    ]);
    expect(updates[2]).toMatchObject({ toolCallId: "t1", kind: "execute", title: "ls src" });
    expect(updates[3]).toMatchObject({ toolCallId: "t1", status: "completed" });
  });

  it("Pi: messages, thinking and tool results", () => {
    const path = record([
      { type: "session", id: "s1", cwd: "/w" },
      {
        type: "message",
        id: "1",
        parentId: null,
        message: { role: "user", content: [{ type: "text", text: "hi" }] },
      },
      {
        type: "message",
        id: "2",
        parentId: "1",
        message: {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "greet" },
            { type: "toolCall", id: "c1", name: "read", arguments: { path: "/w/a" } },
          ],
        },
      },
      {
        type: "message",
        id: "3",
        parentId: "2",
        message: {
          role: "toolResult",
          toolCallId: "c1",
          content: [{ type: "text", text: "data" }],
        },
      },
    ]);
    const { updates } = readRecord("pi", path);
    expect(kinds(updates)).toEqual([
      "user_message_chunk",
      "agent_thought_chunk",
      "tool_call",
      "tool_call_update",
    ]);
    expect(updates[2]).toMatchObject({ kind: "read", locations: [{ path: "/w/a" }] });
  });

  it("Codex: messages and calls, not its setup", () => {
    const path = record([
      {
        type: "response_item",
        payload: {
          type: "message",
          role: "developer",
          content: [{ type: "input_text", text: "rules" }],
        },
      },
      {
        type: "response_item",
        payload: {
          type: "message",
          role: "user",
          content: [{ type: "input_text", text: "<environment_context>x" }],
        },
      },
      {
        type: "response_item",
        payload: {
          type: "message",
          role: "user",
          content: [{ type: "input_text", text: "run tests" }],
        },
      },
      {
        type: "response_item",
        payload: {
          type: "function_call",
          name: "shell",
          call_id: "k",
          arguments: '{"command":"npm test"}',
        },
      },
      {
        type: "response_item",
        payload: { type: "function_call_output", call_id: "k", output: "ok" },
      },
      {
        type: "response_item",
        payload: {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "Done." }],
        },
      },
    ]);
    const { updates } = readRecord("codex", path);
    expect(kinds(updates)).toEqual([
      "user_message_chunk",
      "tool_call",
      "tool_call_update",
      "agent_message_chunk",
    ]);
  });

  it("names the agents and their folders", () => {
    expect(agentFamily("claude-code")).toBe("claude");
    expect(agentFamily("pi")).toBe("pi");
    expect(agentFamily("dsh-tui")).toBeNull();
    expect(claudeFolder("/home/me/my.app")).toBe("-home-me-my-app");
  });
});
