import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { promisify } from "node:util";
import { directServer } from "../transport/direct_server.ts";

const run = promisify(execFile);

/** This machine as Tailscale sees it. */
export interface TailnetSelf {
  /** MagicDNS name without the trailing dot, e.g. `wiang-1.tail1234.ts.net`. */
  dnsName: string;
  /** The short name phones can type, e.g. `wiang-1`. */
  name: string;
  /** The signed-in user, e.g. `you@github`; what `tailscale serve` reports. */
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

/** Runs `tailscale <args>` (`tailscale.exe` from WSL) and parses its JSON. */
async function tailscaleJson(...args: string[]): Promise<unknown> {
  for (const binary of ["tailscale", "tailscale.exe"]) {
    try {
      const { stdout } = await run(binary, args, { timeout: 8_000 });
      return JSON.parse(stdout) as unknown;
    } catch {
      // try the next binary
    }
  }
  return null;
}

export async function tailnetSelf(): Promise<TailnetSelf | null> {
  const status = (await tailscaleJson("status", "--json")) as {
    BackendState?: string;
    Self?: { DNSName?: string; UserID?: number };
    User?: Record<string, { LoginName?: string }>;
  } | null;
  const self = status?.Self;
  const login = status?.User?.[String(self?.UserID)]?.LoginName;
  if (status?.BackendState !== "Running" || !self?.DNSName || !login) return null;
  const dnsName = self.DNSName.replace(/\.$/, "");
  return { dnsName, name: dnsName.split(".")[0]!, login };
}

/**
 * Where phones reach this host —
 * `https://<name>/baya-pair/<label>/direct` — when `tailscale serve` forwards
 * this host's path to its port (serve picks the longest matching mount).
 */
export async function directEndpoint(
  self: TailnetSelf,
  label: HostLabel = hostLabel(),
): Promise<string | null> {
  const serve = (await tailscaleJson("serve", "status", "--json")) as {
    Web?: Record<string, { Handlers?: Record<string, { Proxy?: string }> }>;
  } | null;
  const path = servePath(label);
  const mount = Object.entries(serve?.Web?.[`${self.dnsName}:443`]?.Handlers ?? {})
    .filter(([prefix]) => prefix === "/" || path === prefix || path.startsWith(`${prefix}/`))
    .sort(([a], [b]) => b.length - a.length)[0];
  const proxy = mount?.[1].Proxy ?? "";
  const port = tailnetPairPort(label);
  return /^https?:\/\/(127\.0\.0\.1|localhost):(\d+)/.exec(proxy)?.[2] === String(port)
    ? `https://${self.dnsName}${path}/direct`
    : null;
}

/** The `tailscale serve` command that publishes this host. */
export function serveCommand(label: HostLabel = hostLabel()): string {
  const path = servePath(label);
  return `tailscale serve --bg --set-path ${path} http://127.0.0.1:${tailnetPairPort(label)}${path}`;
}

/**
 * This host's Tailscale endpoint, published by `tailscale serve` at
 * `https://<name>/baya-pair/<label>` and listening on loopback only:
 *
 * - `GET …/info` describes this host and `GET …/pair` issues a pairing code,
 *   both only to devices of this Tailscale account (403 otherwise). Serve
 *   names the caller in `Tailscale-User-Login`, trusted on loopback where
 *   nothing else can set it. Tailscale authenticates and encrypts the
 *   request, so the host key arrives as safely as through a QR code.
 * - a WebSocket upgrade on `…/direct` is a paired phone connecting with no
 *   proxy but `tailscale serve` in between (see [DirectServer]).
 */
export class TailnetPairingServer {
  private server: Server | null = null;
  private lastIssued = 0;
  private readonly info: HostInfo;
  private readonly issue: () => Promise<string>;

  constructor(info: HostInfo, issue: () => Promise<string>) {
    this.info = info;
    this.issue = issue;
  }

  async start(self: TailnetSelf, port = tailnetPairPort(this.info.label)): Promise<void> {
    const base = servePath(this.info.label);
    const handler = async (request: IncomingMessage, response: ServerResponse) => {
      const reply = (status: number, body: object) => {
        response.writeHead(status, { "content-type": "application/json" });
        response.end(JSON.stringify(body));
      };
      const path = (request.url ?? "").split("?")[0];
      const action =
        request.method !== "GET"
          ? null
          : path === `${base}/info`
            ? "info"
            : path === `${base}/pair`
              ? "pair"
              : null;
      if (!action) return reply(404, {});
      const login = request.headers["tailscale-user-login"];
      if (login !== self.login) {
        log(`refused ${String(login ?? "an unknown caller")}`);
        return reply(403, { error: "This device is not signed in to your Tailscale account." });
      }
      if (action === "info") return reply(200, this.info);
      if (Date.now() - this.lastIssued < 1_000) return reply(429, { error: "Try again." });
      this.lastIssued = Date.now();
      try {
        log(`issued a pairing code to ${login}`);
        return reply(200, { uri: await this.issue(), ...this.info });
      } catch (error) {
        return reply(503, { error: error instanceof Error ? error.message : "Not ready." });
      }
    };
    const server = createServer(handler);
    server.on("upgrade", (request, socket, head) => {
      if ((request.url ?? "").split("?")[0] !== `${base}/direct`) return socket.destroy();
      directServer().handleUpgrade(request, socket, head);
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(port, "127.0.0.1", () => resolve());
    });
    this.server = server;
  }

  close(): void {
    this.server?.close();
    this.server = null;
  }
}

function log(message: string): void {
  process.stdout.write(`[baya] tailscale pairing: ${message}\n`);
}
