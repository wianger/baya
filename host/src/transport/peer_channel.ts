import type { ServerMessage } from "../protocol/types.ts";

/** Sink for ServerMessage outbound to the remote app. */
export interface PeerChannel {
  /** Authenticated sender key for pairing and audit paths. */
  readonly remotePeerId?: string;
  send(msg: ServerMessage): void;
}
