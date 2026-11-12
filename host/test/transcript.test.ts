import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { slim, Transcript, trimDiff } from "../src/acp/transcript.ts";

const photo = "/9j/".padEnd(3_000_000, "A");

test("a tool's raw records keep their text but not the photos in them", () => {
  const read = {
    sessionUpdate: "tool_call_update",
    toolCallId: "t1",
    content: [{ type: "content", content: { type: "text", text: "Read image file" } }],
    rawInput: { path: "/w/receipt.jpg" },
    rawOutput: {
      content: [
        { type: "text", text: "Read image file [image/jpeg]" },
        { type: "image", data: photo, mimeType: "image/jpeg" },
      ],
      log: "x".repeat(100_000),
    },
  };
  const slimmed = slim(read);
  expect(slimmed["content"]).toEqual(read.content);
  expect(slimmed["rawInput"]).toEqual(read.rawInput);
  expect(slimmed["rawOutput"]).toEqual({
    content: [
      { type: "text", text: "Read image file [image/jpeg]" },
      { type: "image", mimeType: "image/jpeg" },
    ],
    log: expect.stringMatching(/^x{32768}… \(66 KB more\)$/u),
  });
  expect(JSON.stringify(slimmed).length).toBeLessThan(40_000);
  // Updates without raw records pass as they are.
  const chunk = { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "hi" } };
  expect(slim(chunk)).toBe(chunk);
});

test("a transcript saved before is slimmed as it loads", () => {
  const dir = mkdtempSync(join(tmpdir(), "baya-transcript-"));
  try {
    const path = join(dir, "s.json");
    writeFileSync(
      path,
      JSON.stringify({
        version: 1,
        entries: [
          {
            sessionUpdate: "tool_call",
            toolCallId: "t1",
            title: "Read",
            rawOutput: { type: "image", data: photo },
          },
        ],
      }),
    );
    const transcript = new Transcript(path);
    expect(transcript.updates[0]!["rawOutput"]).toEqual({ type: "image" });
    transcript.flush();
    expect(readFileSync(path, "utf8").length).toBeLessThan(1_000);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an edit sent as the whole file keeps the change and a little around it", () => {
  const file = Array.from({ length: 2000 }, (_, i) => `line ${i + 1}`);
  const edited = [...file];
  edited[999] = "line one thousand";
  const block = {
    type: "diff",
    path: "/w/notes.md",
    oldText: file.join("\n"),
    newText: edited.join("\n"),
  };
  const trimmed = trimDiff(block);
  expect(trimmed["oldText"]).toBe(file.slice(996, 1003).join("\n"));
  expect(trimmed["newText"]).toBe(edited.slice(996, 1003).join("\n"));
  expect(trimmed["_meta"]).toEqual({ baya: { firstLine: 997 } });
  // Trimming again changes nothing; a new file and a small edit stay whole.
  expect(trimDiff(trimmed)).toBe(trimmed);
  const created = { type: "diff", path: "/w/new.md", oldText: "", newText: file.join("\n") };
  expect(trimDiff(created)).toBe(created);
  const small = { type: "diff", path: "/w/a", oldText: "a\nb", newText: "a\nc" };
  expect(trimDiff(small)).toBe(small);
});
