import { execFile } from "node:child_process";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
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
  /** Login of that user, e.g. `you@github`; what `tailscale serve` reports. */
  login: string;
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
    User?: Record<string, { LoginName?: string }>;
  } | null;
  const self = status?.Self;
  const ip = self?.TailscaleIPs?.find((address) => address.includes("."));
  if (status?.BackendState !== "Running" || !ip || !self?.DNSName || self.UserID === undefined) {
    return null;
  }
  const dnsName = self.DNSName.replace(/\.$/, "");
  const login = status.User?.[String(self.UserID)]?.LoginName ?? "";
  return { ip, dnsName, name: dnsName.split(".")[0]!, userId: self.UserID, login };
}

/** The Tailscale user behind a tailnet address, or null if unknown. */
export async function tailnetUserOf(ip: string): Promise<number | null> {
  const who = (await tailscaleJson("whois", ip)) as { UserProfile?: { ID?: number } } | null;
  return who?.UserProfile?.ID ?? null;
}

/**
 * Two ways in, same rule:
 * - direct, on the tailnet address: the caller is identified by
 *   `tailscale whois` on its source address;
 * - through `tailscale serve` (`/baya-pair` → 127.0.0.1): HTTPS on the
 *   machine's MagicDNS name, the path that works when inbound connections
 *   are firewalled (WSL). Serve names the caller in `Tailscale-User-Login`,
 *   which is trusted only on loopback, where nothing else can set it.
 *
 * `GET /pair` hands a fresh pairing code to devices
 * signed in to the same Tailscale account, so a phone pairs by typing this
 * computer's name instead of scanning. Tailscale authenticates the caller's
 * address and encrypts the request, so the host key arrives as safely as
 * through a QR code. Anyone else gets 403.
 */
export class TailnetPairingServer {
  private readonly servers: Server[] = [];
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
    const handler = async (request: IncomingMessage, response: ServerResponse) => {
      const reply = (status: number, body: Record<string, unknown>) => {
        response.writeHead(status, { "content-type": "application/json" });
        response.end(JSON.stringify(body));
      };
      const caller = (request.socket.remoteAddress ?? "").replace(/^::ffff:/, "");
      const path = (request.url ?? "").split("?")[0];
      // `tailscale serve` may or may not strip its mount path.
      if (request.method !== "GET" || !(path === "/pair" || path?.endsWith("/baya-pair/pair"))) {
        return reply(404, {});
      }
      const login = request.headers["tailscale-user-login"];
      const viaServe = (caller === "127.0.0.1" || caller === "::1") && typeof login === "string";
      const allowed = viaServe
        ? login === self.login && self.login !== ""
        : (await this.whois(caller)) === self.userId;
      if (!allowed) {
        const who = viaServe
          ? String(request.headers["tailscale-user-login"] ?? "no login")
          : caller;
        log(`refused ${who}`);
        return reply(403, { error: "This device is not signed in to your Tailscale account." });
      }
      if (Date.now() - this.lastIssued < 1_000) return reply(429, { error: "Try again." });
      this.lastIssued = Date.now();
      try {
        log(`issued a pairing code to ${caller}`);
        return reply(200, { uri: await this.issue(), name: self.name });
      } catch (error) {
        return reply(503, { error: error instanceof Error ? error.message : "Not ready." });
      }
    };
    // The tailnet address for direct callers, loopback for `tailscale serve`.
    for (const address of new Set([self.ip, "127.0.0.1"])) {
      const server = createServer(handler);
      server.on("connection", (socket) => log(`connection from ${socket.remoteAddress}`));
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, address, () => resolve());
      });
      this.servers.push(server);
    }
  }

  close(): void {
    for (const server of this.servers.splice(0)) server.close();
  }
}

function log(message: string): void {
  process.stdout.write(`[baya] tailscale pairing: ${message}\n`);
}
