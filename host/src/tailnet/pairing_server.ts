import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
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

/**
 * Which Baya on this machine: WSL and Windows can both run one, sharing a
 * Tailscale name and (in mirrored networking) their ports.
 */
export type HostLabel = "windows" | "wsl" | "linux" | "macos";

export function hostLabel(): HostLabel {
  if (process.platform === "win32") return "windows";
  if (process.platform === "darwin") return "macos";
  try {
    if (readFileSync("/proc/version", "utf8").toLowerCase().includes("microsoft")) return "wsl";
  } catch {
    // not WSL
  }
  return "linux";
}

/** One port per label so a Windows and a WSL host can listen side by side. */
export function tailnetPairPort(label: HostLabel = hostLabel()): number {
  const override = Number(process.env["BAYA_TAILNET_PORT"]);
  if (Number.isInteger(override) && override > 0) return override;
  return label === "windows" ? 7481 : 7480;
}

/** The `tailscale serve` path for this host's pairing endpoint. */
export function servePath(label: HostLabel = hostLabel()): string {
  return `/baya-pair/${label}`;
}

/** What `/info` tells an authorized phone about this host. */
export interface HostInfo {
  label: HostLabel;
  name: string;
  /** Host public key (base64), so a phone can tell hosts apart. */
  key: string;
}

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
 * This host's pairing endpoint. Two ways in, same rule:
 * - through `tailscale serve` (`/baya-pair/<label>` → 127.0.0.1): HTTPS on
 *   the machine's MagicDNS name, which works when inbound connections are
 *   firewalled (WSL). Serve names the caller in `Tailscale-User-Login`,
 *   trusted only on loopback, where nothing else can set it;
 * - direct, on the tailnet address: the caller is identified by
 *   `tailscale whois` on its source address.
 *
 * `GET …/info` describes this host and `GET …/pair` issues a pairing code,
 * both only to devices of the same Tailscale account (403 otherwise).
 * Tailscale authenticates and encrypts the request, so the host key
 * arrives as safely as through a QR code. `/baya-pair/{info,pair}` without
 * a label stays as the pre-label serve mapping.
 */
export class TailnetPairingServer {
  private readonly servers: Server[] = [];
  private lastIssued = 0;
  private readonly info: HostInfo;
  private readonly issue: () => Promise<string>;
  private readonly whois: (ip: string) => Promise<number | null>;

  constructor(
    info: HostInfo,
    issue: () => Promise<string>,
    whois: (ip: string) => Promise<number | null> = tailnetUserOf,
  ) {
    this.info = info;
    this.issue = issue;
    this.whois = whois;
  }

  /** `info` or `pair` when [path] addresses this host, else null. */
  private route(path: string): "info" | "pair" | null {
    for (const action of ["info", "pair"] as const) {
      if (
        path === `/${action}` ||
        path === `/baya-pair/${action}` ||
        path.endsWith(`/baya-pair/${this.info.label}/${action}`)
      ) {
        return action;
      }
    }
    return null;
  }

  async start(self: TailnetSelf, port = tailnetPairPort(this.info.label)): Promise<void> {
    const handler = async (request: IncomingMessage, response: ServerResponse) => {
      const reply = (status: number, body: object) => {
        response.writeHead(status, { "content-type": "application/json" });
        response.end(JSON.stringify(body));
      };
      const caller = (request.socket.remoteAddress ?? "").replace(/^::ffff:/, "");
      const action =
        request.method === "GET" ? this.route((request.url ?? "").split("?")[0]!) : null;
      if (!action) return reply(404, {});
      const login = request.headers["tailscale-user-login"];
      const viaServe = (caller === "127.0.0.1" || caller === "::1") && typeof login === "string";
      const allowed = viaServe
        ? login === self.login && self.login !== ""
        : (await this.whois(caller)) === self.userId;
      if (!allowed) {
        log(`refused ${viaServe ? String(login) : caller}`);
        return reply(403, { error: "This device is not signed in to your Tailscale account." });
      }
      if (action === "info") return reply(200, this.info);
      if (Date.now() - this.lastIssued < 1_000) return reply(429, { error: "Try again." });
      this.lastIssued = Date.now();
      try {
        log(`issued a pairing code to ${viaServe ? String(login) : caller}`);
        return reply(200, { uri: await this.issue(), ...this.info });
      } catch (error) {
        return reply(503, { error: error instanceof Error ? error.message : "Not ready." });
      }
    };
    // The tailnet address for direct callers, loopback for `tailscale serve`.
    for (const address of new Set([self.ip, "127.0.0.1"])) {
      const server = createServer(handler);
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
