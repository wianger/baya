import { describe, expect, it } from "vitest";
import type { ChannelHandler, HerdrCore } from "../src/herdr/core.ts";
import { PhoneTerminals } from "../src/herdr/phone_terminals.ts";

type Json = Record<string, unknown>;

function fakeCore() {
  const opened: { params: Json; handler: ChannelHandler; channel: number }[] = [];
  const sent: { channel: number; kind: number; payload: Buffer }[] = [];
  const core = {
    available: async () => true,
    call: async () => ({}),
    open: async (_method: string, params: Json, handler: ChannelHandler) => {
      const channel = opened.length + 1;
      opened.push({ params, handler, channel });
      return { channel, terminal: { address: params["terminal"], cols: 142, rows: 39 } };
    },
    send: (channel: number, kind: number, payload: Buffer = Buffer.alloc(0)) =>
      sent.push({ channel, kind, payload }),
    closeChannel: () => {},
  } as unknown as HerdrCore;
  return { core, opened, sent };
}

describe("watching a terminal as it is", () => {
  it("keeps the computer's size, tells the phone each size, and types without resizing", async () => {
    const { core, opened, sent } = fakeCore();
    const notes: { method: string; params: Json }[] = [];
    const terminals = new PhoneTerminals(
      { notify: (method, params) => notes.push({ method, params }), sendData: async () => {} },
      core,
    );
    await terminals.attach({ terminal: "t3", stream: 7, observe: true, cols: 40, rows: 20 });
    expect(opened[0]!.params).toMatchObject({ observe: true, resize_notifications: true });

    // Ready to type at once, at the size the terminal has.
    await new Promise((r) => setTimeout(r, 0));
    const typing = opened[1]!;
    expect(typing.params).toMatchObject({ terminal: "t3", cols: 142, rows: 39 });
    expect(typing.params["observe"]).toBeUndefined();

    opened[0]!.handler.resize?.(150, 40);
    await new Promise((r) => setTimeout(r, 0));
    expect(notes).toContainEqual({
      method: "_baya/terminal_size",
      params: { stream: 7, cols: 150, rows: 40 },
    });
    // The typing attach follows the computer's size…
    const resized = sent.filter((f) => f.channel === typing.channel && f.kind === 3);
    expect(resized.at(-1)?.payload.readUInt16LE(0)).toBe(150);

    // …and the phone's own size never reaches either.
    const before = sent.length;
    terminals.resize(7, 40, 20);
    expect(sent).toHaveLength(before);

    terminals.input(7, "a");
    expect(sent.filter((f) => f.channel === typing.channel && f.kind === 0)).toHaveLength(1);
  });
});
