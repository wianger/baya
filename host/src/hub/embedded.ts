import { join } from "node:path";
import { BAYA_HOME } from "../config.ts";
import { Hub } from "./hub.ts";

let hub: Hub | null = null;
let starting: Promise<boolean> | null = null;

/** Loopback relay addresses are ones this host can serve itself. */
export function servableLocally(relayUrl: string): { port: number } | null {
  if (process.env["BAYA_NO_HUB"] === "1") return null;
  try {
    const url = new URL(relayUrl);
    if (!["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) return null;
    const port = Number(
      url.port || (url.protocol === "https:" || url.protocol === "wss:" ? 443 : 80),
    );
    return Number.isInteger(port) && port > 0 ? { port } : null;
  } catch {
    return null;
  }
}

/**
 * Serve the local relay address if its port is free. The first Baya on the
 * machine to bind it wins and the others connect to it as clients; when the
 * winner exits, the next reconnect elects a new one. Resolves `true` when
 * this call started the hub.
 */
export function serveHubIfFree(relayUrl: string): Promise<boolean> {
  const local = servableLocally(relayUrl);
  if (!local || hub) return Promise.resolve(false);
  starting ??= (async () => {
    const candidate = new Hub({ meshFile: join(BAYA_HOME, "hub", "mesh.json") });
    try {
      await candidate.listen(local.port);
      hub = candidate;
      process.stdout.write(`[baya] Serving the relay on 127.0.0.1:${local.port}\n`);
      return true;
    } catch {
      return false; // someone else took the port
    } finally {
      starting = null;
    }
  })();
  return starting;
}

export function hubRunning(): boolean {
  return hub !== null;
}

export function stopHub(): void {
  hub?.close();
  hub = null;
}
