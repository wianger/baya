import type { ServerMessage } from "../protocol/types.js";

/** Sink for ServerMessage outbound to the remote app. */
export interface PeerChannel {
  /** Authenticated relay sender key for pairing and audit paths. */
  readonly remotePeerId?: string;
  send(msg: ServerMessage): void;
}
