// Regenerates .orchestration/contracts/noise_baya_vector.json, the Baya
// handshake both implementations must reproduce: `node test/make-noise-vector.ts`.
import { createPrivateKey, createPublicKey } from "node:crypto";
import { writeFileSync } from "node:fs";
import { PROLOGUE } from "../src/transport/direct_server.ts";
import {
  Initiator,
  keyPairFromPrivate,
  Responder,
  sealMessage,
  x25519FromEd25519Seed,
} from "../src/transport/noise.ts";

const edPublic = (seed: Buffer) =>
  Buffer.from(
    createPublicKey(
      createPrivateKey({
        key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]),
        format: "der",
        type: "pkcs8",
      }),
    ).export({ format: "jwk" }).x!,
    "base64url",
  );

const phoneSeed = Buffer.alloc(32, 1);
const hostSeed = Buffer.alloc(32, 2);
const phoneEphemeral = Buffer.alloc(32, 3);
const hostEphemeral = Buffer.alloc(32, 4);
const phoneEd = edPublic(phoneSeed);
const hostEd = edPublic(hostSeed);
const hostStatic = keyPairFromPrivate(x25519FromEd25519Seed(hostSeed));
const hello = JSON.stringify({ ed25519: phoneEd.toString("base64") });

const initiator = new Initiator({
  prologue: PROLOGUE,
  staticKey: keyPairFromPrivate(x25519FromEd25519Seed(phoneSeed)),
  remoteStatic: hostStatic.publicKey,
  ephemeral: keyPairFromPrivate(phoneEphemeral),
});
const responder = new Responder({
  prologue: PROLOGUE,
  staticKey: hostStatic,
  ephemeral: keyPairFromPrivate(hostEphemeral),
});
const message1 = initiator.writeMessage(Buffer.from(hello));
responder.readMessage(message1);
const reply = responder.writeMessage(Buffer.from("{}"));
const phone = initiator.readMessage(reply.message).session;
const request = '{"jsonrpc":"2.0","id":1,"method":"session/list","params":{}}';
const response = '{"jsonrpc":"2.0","id":1,"result":{"sessions":[]}}';
const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64");

writeFileSync(
  new URL("../../.orchestration/contracts/noise_baya_vector.json", import.meta.url),
  `${JSON.stringify(
    {
      prologue: PROLOGUE.toString("ascii"),
      phone_ed25519_seed: b64(phoneSeed),
      phone_ed25519_public: b64(phoneEd),
      host_ed25519_seed: b64(hostSeed),
      host_ed25519_public: b64(hostEd),
      host_x25519_public: b64(hostStatic.publicKey),
      phone_ephemeral: b64(phoneEphemeral),
      host_ephemeral: b64(hostEphemeral),
      hello,
      message1: b64(message1),
      message2: b64(reply.message),
      handshake_hash: b64(phone.handshakeHash),
      request,
      request_frame: b64(sealMessage(phone.send, Buffer.from(request))[0]!),
      response,
      response_frame: b64(sealMessage(reply.session.send, Buffer.from(response))[0]!),
    },
    null,
    2,
  )}\n`,
);
