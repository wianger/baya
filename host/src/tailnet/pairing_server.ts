import { execFile } from "node:child_process";
import { createServer, type Server } from "node:http";
import { promisify } from "node:util";

const run = promisify(execFile);

/** This machine as Tailscale sees it. */
export interface TailnetSelf {
  ip: string;
  /** MagicDNS name without the trailing dot, e.g. `wiang-1.tail1234.ts.net`. */
  dnsName: string;
  /** The short name phones can type, e.g. `wiang-1`. */
  name: string;
  userId: number;
}

export const TAILNET_PAIR_PORT = Number(process.env["BAYA_TAILNET_PORT"] ?? 7480);

/**
 * Runs `tailscale <command> --json [args]` (`tailscale.exe` from WSL). Go's
 * flag parser stops at the first positional, so `--json` must come first.
 */
async function tailscaleJson(command: string, ...args: string[]): Promise<unknown> {
  for (const binary of ["tailscale", "tailscale.exe"]) {
    try {
      const { stdout } = await run(binary, [command, "--json", ...args], { timeout: 8_000 });
      return JSON.parse(stdout) as unknown;
    } catch {
      // try the next binary
    }
  }
  return null;
}

export async function tailnetSelf(): Promise<TailnetSelf | null> {
  const status = (await tailscaleJson("status")) as {
    BackendState?: string;
    Self?: { DNSName?: string; TailscaleIPs?: string[]; UserID?: number };
  } | null;
  const self = status?.Self;
  const ip = self?.TailscaleIPs?.find((address) => address.includes("."));
  if (status?.BackendState !== "Running" || !ip || !self?.DNSName || self.UserID === undefined) {
    return null;
  }
  const dnsName = self.DNSName.replace(/\.$/, "");
  return { ip, dnsName, name: dnsName.split(".")[0]!, userId: self.UserID };
}

/** The Tailscale user behind a tailnet address, or null if unknown. */
export async function tailnetUserOf(ip: string): Promise<number | null> {
  const who = (await tailscaleJson("whois", ip)) as { UserProfile?: { ID?: number } } | null;
  return who?.UserProfile?.ID ?? null;
}

/**
 * `GET /pair` on the tailnet address hands a fresh pairing code to devices
 * signed in to the same Tailscale account, so a phone pairs by typing this
 * computer's name instead of scanning. Tailscale authenticates the caller's
 * address and encrypts the request, so the host key arrives as safely as
 * through a QR code. Anyone else gets 403.
 */
export class TailnetPairingServer {
  private server: Server | null = null;
  private lastIssued = 0;
  private readonly issue: () => Promise<string>;
  private readonly whois: (ip: string) => Promise<number | null>;

  constructor(
    issue: () => Promise<string>,
    whois: (ip: string) => Promise<number | null> = tailnetUserOf,
  ) {
    this.issue = issue;
    this.whois = whois;
  }

  async start(self: TailnetSelf, port = TAILNET_PAIR_PORT): Promise<void> {
    const server = createServer(async (request, response) => {
      const reply = (status: number, body: Record<string, unknown>) => {
        response.writeHead(status, { "content-type": "application/json" });
        response.end(JSON.stringify(body));
      };
      if (request.method !== "GET" || request.url !== "/pair") return reply(404, {});
      const caller = (request.socket.remoteAddress ?? "").replace(/^::ffff:/, "");
      if ((await this.whois(caller)) !== self.userId) {
        return reply(403, { error: "This device is not signed in to your Tailscale account." });
      }
      if (Date.now() - this.lastIssued < 1_000) return reply(429, { error: "Try again." });
      this.lastIssued = Date.now();
      try {
        return reply(200, { uri: await this.issue(), name: self.name });
      } catch (error) {
        return reply(503, { error: error instanceof Error ? error.message : "Not ready." });
      }
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(port, self.ip, () => resolve());
    });
    this.server = server;
  }

  close(): void {
    this.server?.close();
    this.server = null;
  }
}
