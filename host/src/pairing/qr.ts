import { renderUnicodeCompact } from "uqr";

export interface PairingInvite {
  token: string;
  publicKey: Uint8Array;
  sessionName: string;
  roomId: string;
  /** The relay this host listens on; the phone adopts it when scanning. */
  relayUrl: string;
}

/**
 * `baya://pair?t&epk&n&rm&r` — everything the phone needs, so pairing never
 * asks the user to type a relay address. `rm` routes the first
 * `pair_request` to the session room that issued the token.
 */
export function buildQRUri(invite: PairingInvite): string {
  const params = new URLSearchParams({
    t: invite.token,
    epk: Buffer.from(invite.publicKey).toString("base64url"),
    n: invite.sessionName.slice(0, 80),
    rm: invite.roomId,
    r: invite.relayUrl,
  });
  return `baya://pair?${params.toString()}`;
}

/** Prints the QR with Unicode half blocks so it fits a normal terminal. */
export function displayQR(uri: string): void {
  const qrcode = renderUnicodeCompact(uri, { border: 2 });
  process.stdout.write(`\nScan with Baya on your phone:\n\n${qrcode}\n`);
}
