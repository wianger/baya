import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";
import {
  generateKeyPair,
  Initiator,
  keyPairFromPrivate,
  MAX_PIECE,
  MessageReader,
  NoiseError,
  Responder,
  sealMessage,
} from "../src/transport/noise.ts";

const vector = JSON.parse(
  readFileSync(
    new URL("../../.orchestration/contracts/noise_ik_vector.json", import.meta.url),
    "utf8",
  ),
) as {
  init_prologue: string;
  init_static: string;
  init_ephemeral: string;
  init_remote_static: string;
  resp_static: string;
  resp_ephemeral: string;
  handshake_hash: string;
  messages: Array<{ payload: string; ciphertext: string }>;
};
const hex = (value: string) => Buffer.from(value, "hex");

describe("Noise_IK_25519_ChaChaPoly_SHA256", () => {
  test("matches the cacophony test vector, handshake and transport", () => {
    const initiator = new Initiator({
      prologue: hex(vector.init_prologue),
      staticKey: keyPairFromPrivate(hex(vector.init_static)),
      remoteStatic: hex(vector.init_remote_static),
      ephemeral: keyPairFromPrivate(hex(vector.init_ephemeral)),
    });
    const responder = new Responder({
      prologue: hex(vector.init_prologue),
      staticKey: keyPairFromPrivate(hex(vector.resp_static)),
      ephemeral: keyPairFromPrivate(hex(vector.resp_ephemeral)),
    });
    const [m1, m2, ...rest] = vector.messages;
    const first = initiator.writeMessage(hex(m1!.payload));
    expect(first.toString("hex")).toBe(m1!.ciphertext);
    expect(responder.readMessage(first).payload.toString("hex")).toBe(m1!.payload);
    const second = responder.writeMessage(hex(m2!.payload));
    expect(second.message.toString("hex")).toBe(m2!.ciphertext);
    const done = initiator.readMessage(second.message);
    expect(done.payload.toString("hex")).toBe(m2!.payload);
    expect(done.session.handshakeHash.toString("hex")).toBe(vector.handshake_hash);
    expect(second.session.handshakeHash.toString("hex")).toBe(vector.handshake_hash);

    // Transport messages alternate, starting with the initiator.
    rest.forEach((message, index) => {
      const [from, to] =
        index % 2 === 0 ? [done.session, second.session] : [second.session, done.session];
      const ciphertext = from.send.encrypt(Buffer.alloc(0), hex(message.payload));
      expect(ciphertext.toString("hex")).toBe(message.ciphertext);
      expect(to.receive.decrypt(Buffer.alloc(0), ciphertext).toString("hex")).toBe(message.payload);
    });
  });

  test("the responder learns the initiator's static key; a wrong key fails", () => {
    const phone = generateKeyPair();
    const host = generateKeyPair();
    const responder = new Responder({ prologue: Buffer.from("p"), staticKey: host });
    const hello = new Initiator({
      prologue: Buffer.from("p"),
      staticKey: phone,
      remoteStatic: host.publicKey,
    }).writeMessage(Buffer.from("hi"));
    expect(responder.readMessage(hello).remoteStatic).toEqual(phone.publicKey);

    const impostor = new Responder({ prologue: Buffer.from("p"), staticKey: generateKeyPair() });
    expect(() => impostor.readMessage(hello)).toThrow(NoiseError);
  });

  test("a different prologue fails the handshake", () => {
    const host = generateKeyPair();
    const hello = new Initiator({
      prologue: Buffer.from("a"),
      staticKey: generateKeyPair(),
      remoteStatic: host.publicKey,
    }).writeMessage(Buffer.alloc(0));
    expect(() =>
      new Responder({ prologue: Buffer.from("b"), staticKey: host }).readMessage(hello),
    ).toThrow(NoiseError);
  });
});

describe("message framing", () => {
  function pair() {
    const host = generateKeyPair();
    const initiator = new Initiator({
      prologue: Buffer.alloc(0),
      staticKey: generateKeyPair(),
      remoteStatic: host.publicKey,
    });
    const responder = new Responder({ prologue: Buffer.alloc(0), staticKey: host });
    responder.readMessage(initiator.writeMessage(Buffer.alloc(0)));
    const reply = responder.writeMessage(Buffer.alloc(0));
    return { phone: initiator.readMessage(reply.message).session, host: reply.session };
  }

  test("large messages are split and reassembled; small ones are one frame", () => {
    const { phone, host } = pair();
    const reader = new MessageReader();
    const small = sealMessage(phone.send, Buffer.from("{}"));
    expect(small).toHaveLength(1);
    expect(reader.read(host.receive, small[0]!)?.toString()).toBe("{}");

    const big = Buffer.alloc(MAX_PIECE * 2 + 10, 7);
    const frames = sealMessage(phone.send, big);
    expect(frames).toHaveLength(3);
    expect(reader.read(host.receive, frames[0]!)).toBeNull();
    expect(reader.read(host.receive, frames[1]!)).toBeNull();
    expect(reader.read(host.receive, frames[2]!)).toEqual(big);
  });

  test("a replayed, reordered or tampered frame fails", () => {
    const { phone, host } = pair();
    const reader = new MessageReader();
    sealMessage(phone.send, Buffer.from("a"));
    const [b] = sealMessage(phone.send, Buffer.from("b"));
    // Out of order: the receiver still expects the first message.
    expect(() => reader.read(host.receive, b!)).toThrow(NoiseError);
    const fresh = pair();
    const [x] = sealMessage(fresh.phone.send, Buffer.from("x"));
    fresh.host.receive.decrypt(Buffer.alloc(0), x!);
    expect(() => fresh.host.receive.decrypt(Buffer.alloc(0), x!)).toThrow(NoiseError);
  });
});
