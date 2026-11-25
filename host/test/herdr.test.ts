import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import { encodeFrame, FrameReader, HerdrCore } from "../src/herdr/core.ts";
import { PhoneTerminals, resumeCommand } from "../src/herdr/phone_terminals.ts";

const fake = fileURLToPath(new URL("./fixtures/fake-hc.mjs", import.meta.url));

class Phone {
  readonly notes: Array<{ method: string; params: Record<string, unknown> }> = [];
  readonly bytes: Array<{ stream: number; offset: number; text: string }> = [];
  notify(method: string, params: Record<string, unknown>) {
    this.notes.push({ method, params });
  }
  async sendData(stream: number, offset: number, bytes: Buffer) {
    this.bytes.push({ stream, offset, text: bytes.toString() });
  }
}

async function until(check: () => boolean): Promise<void> {
  const end = Date.now() + 5000;
  while (!check()) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe("herdr-core", () => {
  let core: HerdrCore | undefined;
  afterEach(() => core?.dispose());

  it("reads frames split anywhere", () => {
    const reader = new FrameReader();
    const whole = Buffer.concat([
      encodeFrame(0, 0, Buffer.from("{}")),
      encodeFrame(7, 3, Buffer.from([80, 0, 24, 0])),
    ]);
    expect(reader.push(whole.subarray(0, 5))).toEqual([]);
    const frames = reader.push(whole.subarray(5));
    expect(frames.map((f) => [f.channel, f.kind, f.payload.length])).toEqual([
      [0, 0, 2],
      [7, 3, 4],
    ]);
  });

  it("streams a terminal to the phone, with keys, sizes and credit back", async () => {
    core = new HerdrCore(async () => [process.execPath, fake]);
    const hc = core;
    const phone = new Phone();
    const terminals = new PhoneTerminals(phone, hc);

    const attached = await terminals.attach({ terminal: "t1", stream: 9, cols: 50, rows: 20 });
    expect(attached["terminal"]).toMatchObject({ address: "t1" });
    await until(() => phone.bytes.length === 1);
    expect(phone.bytes[0]).toEqual({ stream: 9, offset: 0, text: "paint 50x20 history=300" });

    terminals.input(9, "ls\r");
    terminals.resize(9, 61, 17);
    await until(() => phone.bytes.length === 3);
    expect(phone.bytes.slice(1)).toEqual([
      { stream: 9, offset: 23, text: "echo:ls\r" },
      { stream: 9, offset: 31, text: "size:61x17" },
    ]);
    // Every byte the phone took went back to hc as credit.
    const { credit } = await hc.call("terminal.get", { terminal: "t1" });
    expect(credit).toBe(41);

    await terminals.kill("t1");
    await until(() => phone.notes.some((n) => n.method === "_baya/terminal_closed"));
    expect(phone.notes.find((n) => n.method === "_baya/terminal_closed")!.params).toEqual({
      stream: 9,
      reason: "killed",
      exit_code: 0,
    });
    terminals.close();
  });

  it("errors carry hc's hint, and a lost core comes back on the next call", async () => {
    core = new HerdrCore(async () => [process.execPath, fake]);
    const hc = core;
    await expect(hc.call("terminal.nope", {})).rejects.toThrow("no terminal.nope — try t1");
    hc.dispose();
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(await hc.call("terminal.list", {})).toMatchObject({ terminals: [{ address: "t1" }] });
  });

  it("reads a terminal's history as text, at most ten thousand lines", async () => {
    core = new HerdrCore(async () => [process.execPath, fake]);
    const terminals = new PhoneTerminals(new Phone(), core);
    expect(await terminals.read("t1", 500)).toMatchObject({ text: "read t1 lines=500" });
    expect(await terminals.read("t1", 99_999)).toMatchObject({ text: "read t1 lines=10000" });
    terminals.close();
  });

  it("says when hc is not installed", async () => {
    const hc = new HerdrCore(async () => null);
    core = hc;
    const terminals = new PhoneTerminals(new Phone(), hc);
    expect(await terminals.list()).toEqual({ available: false, terminals: [] });
    await expect(hc.call("terminal.list", {})).rejects.toMatchObject({ kind: "not_installed" });
  });
});

describe("a session's terminal", () => {
  it("reopens the agent's own conversation where its CLI can", () => {
    expect(resumeCommand("claude", "abc-1", { CLAUDE_CODE_EXECUTABLE: "/u/claude" })).toBe(
      "/u/claude --resume abc-1",
    );
    expect(resumeCommand("codex", "t 1")).toBe("codex resume 't 1'");
    expect(resumeCommand("pi", "p1")).toBe("pi --session p1");
    expect(resumeCommand("deepseek", "d1")).toBeNull();
    expect(resumeCommand("claude", null)).toBeNull();
  });
});
