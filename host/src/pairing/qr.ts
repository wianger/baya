import { renderUnicodeCompact } from "uqr";

export interface PairingInvite {
  token: string;
  publicKey: Uint8Array;
  /** What the app calls this computer until the user renames it. */
  name: string;
  /** Where the phone reaches this host (its `…/direct` address). */
  endpoint: string;
}

/** `baya://pair?t&epk&n&e` — everything the phone needs; `e` is where it reaches this host. */
export function buildQRUri(invite: PairingInvite): string {
  const params = new URLSearchParams({
    t: invite.token,
    epk: Buffer.from(invite.publicKey).toString("base64url"),
    n: invite.name.slice(0, 80),
    e: invite.endpoint,
  });
  return `baya://pair?${params.toString()}`;
}

/** Prints the QR with Unicode half blocks so it fits a normal terminal. */
export function displayQR(uri: string): void {
  process.stdout.write(`\n${renderUnicodeCompact(uri, { border: 2 })}\n`);
}
