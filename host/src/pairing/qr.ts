import qrTerminal from "qrcode-terminal";

/**
 * Builds the pairing URI. The `remotepi://` scheme is kept so the installed
 * Android package keeps handling it. `rm` routes the phone's `pair_request`
 * to the session room that issued the token.
 */
export function buildQRUri(
  token: string,
  publicKey: Uint8Array,
  sessionName: string,
  roomId: string,
): string {
  const params = new URLSearchParams({
    t: token,
    epk: Buffer.from(publicKey).toString("base64url"),
    n: sessionName.slice(0, 80),
    rm: roomId,
  });
  return `remotepi://pair?${params.toString()}`;
}

/** Prints the QR with Unicode half blocks so it fits a normal terminal. */
export function displayQR(uri: string): void {
  qrTerminal.generate(uri, { small: true }, (qrcode) => {
    process.stdout.write(`\nScan with Baya on your phone:\n\n${qrcode}\n`);
  });
}
