import { hostname } from "node:os";
import type { ClientMessage, ServerMessage } from "../protocol/types.ts";
import type { PeerChannel } from "../transport/peer_channel.ts";
import { addPeer } from "./storage.ts";
import { consumePendingPairToken } from "./token_store.ts";

export interface PairingContext {
  roomId: string;
  sessionName: string;
  sessionStartedAt: number;
  harnessName: string;
  harnessVersion: string;
}

export class PairingService {
  async handle(
    sender: PeerChannel,
    message: ClientMessage,
    context: PairingContext,
  ): Promise<boolean> {
    if (message.type !== "pair_request") return false;

    const status = consumePendingPairToken(message.token, context.roomId);
    if (status !== "ok") {
      const code =
        status === "expired"
          ? "token_expired"
          : status === "consumed"
            ? "token_consumed"
            : "token_unknown";
      const text =
        code === "token_expired"
          ? "This pairing code has expired. Run `baya pair` again."
          : code === "token_consumed"
            ? "This pairing code was already used. Run `baya pair` again."
            : "This pairing code was not issued for this Baya session.";
      sender.send({ type: "pair_error", in_reply_to: message.id, code, message: text });
      return true;
    }

    // The sender id is the phone's Ed25519 public key. A
    // challenge-response already proved possession before this frame arrives.
    const remote = (sender as PeerChannel & { remotePeerId?: string }).remotePeerId;
    if (!remote) {
      sender.send({
        type: "pair_error",
        in_reply_to: message.id,
        code: "internal_error",
        message: "The connection did not provide the device identity.",
      });
      return true;
    }

    await addPeer({
      name: message.device_name,
      remote_epk: remote,
      paired_at: new Date().toISOString(),
    });
    const reply: ServerMessage = {
      type: "pair_ok",
      in_reply_to: message.id,
      session_name: context.sessionName,
      session_started_at: context.sessionStartedAt,
      room_id: context.roomId,
      harness: {
        name: context.harnessName,
        version: context.harnessVersion,
      },
      hostname: hostname(),
    };
    sender.send(reply);
    return true;
  }
}
