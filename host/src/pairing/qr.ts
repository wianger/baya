import { renderUnicodeCompact } from "uqr";

export interface PairingInvite {
  token: string;
  publicKey: Uint8Array;
  sessionName: string;
  roomId: string;
  /** Where the phone reaches this host (its `…/direct` address). */
  endpoint: string;
}

/**
 * `baya://pair?t&epk&n&rm&e` — everything the phone needs: `e` is where it
 * reaches this host, `rm` routes the first `pair_request` to the session
 * room that issued the token.
 */
export function buildQRUri(invite: PairingInvite): string {
  const params = new URLSearchParams({
    t: invite.token,
    epk: Buffer.from(invite.publicKey).toString("base64url"),
    n: invite.sessionName.slice(0, 80),
    rm: invite.roomId,
    e: invite.endpoint,
  });
  return `baya://pair?${params.toString()}`;
}

/** Prints the QR with Unicode half blocks so it fits a normal terminal. */
export function displayQR(uri: string): void {
  process.stdout.write(`\n${renderUnicodeCompact(uri, { border: 2 })}\n`);
}
