import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";

/**
 * Relay room id of one Baya session: 12 chars of base64url(sha256) over the
 * resolved folder and the session's `agent:id` key, so several sessions in
 * one folder never share a room and symlinked paths agree.
 */
export function roomIdFor(cwd: string, sessionKey: string): string {
  let target: string;
  try {
    target = realpathSync(cwd);
  } catch {
    target = cwd;
  }
  // NUL cannot appear in a path, so the folder/key boundary is unambiguous.
  return createHash("sha256")
    .update(`${target}\u0000${sessionKey}`)
    .digest("base64url")
    .slice(0, 12);
}

/** Short stable key the phone compares against its cached sessions. */
export function sessionKeyForId(sessionId: string): string {
  return createHash("sha256").update(sessionId).digest("base64url").slice(0, 16);
}
