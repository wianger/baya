/**
 * Web preview: the phone shows a site served on this computer (a dev server
 * on `localhost:5173`, say) without that server being exposed anywhere.
 *
 * Requests reach the host through `tailscale serve`, on this host's path at
 * `…/preview/<path>`, so only devices signed in to the owner's Tailscale
 * account get this far. Each also carries a token the phone got over the
 * end-to-end encrypted ACP connection (`_baya/preview_open`), which names
 * the one port it may reach. The host forwards the request to that port on
 * loopback as if it came from a local browser, WebSocket upgrades included
 * (hot reload keeps working).
 */
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import {
  request as httpRequest,
  type IncomingHttpHeaders,
  type IncomingMessage,
  type OutgoingHttpHeaders,
  type ServerResponse,
} from "node:http";
import type { Duplex } from "node:stream";
import { promisify } from "node:util";

const run = promisify(execFile);

export const PREVIEW_TOKEN_HEADER = "x-baya-preview";

/** A port something listens on, as the phone lists it. */
interface PreviewPort {
  port: number;
  /** HTTP status of `GET /`. */
  status: number;
  /** The page's `<title>`, or "". */
  title: string;
  html: boolean;
}

// Headers that describe the hop from the phone, not the request itself.
const HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-connection",
  "transfer-encoding",
  "te",
  "trailer",
  "upgrade",
  "forwarded",
  "x-forwarded-for",
  "x-forwarded-host",
  "x-forwarded-proto",
  "x-forwarded-port",
  PREVIEW_TOKEN_HEADER,
]);

/** The request's headers as a local browser on [port] would send them. */
export function upstreamHeaders(headers: IncomingHttpHeaders, port: number): OutgoingHttpHeaders {
  const local = `localhost:${port}`;
  const out: OutgoingHttpHeaders = {};
  for (const [name, value] of Object.entries(headers)) {
    if (value === undefined || HOP_HEADERS.has(name) || name.startsWith("tailscale-")) continue;
    out[name] = value;
  }
  out["host"] = local;
  if (typeof out["origin"] === "string") out["origin"] = `http://${local}`;
  if (typeof out["referer"] === "string") {
    try {
      const referer = new URL(out["referer"]);
      out["referer"] = `http://${local}${referer.pathname}${referer.search}`;
    } catch {
      delete out["referer"];
    }
  }
  return out;
}

/** A redirect to the dev server itself, made relative so it stays in the preview. */
export function localRedirect(location: string, port: number): string {
  try {
    const url = new URL(location);
    const local = ["localhost", "127.0.0.1", "[::1]", "0.0.0.0"].includes(url.hostname);
    if (local && Number(url.port || 80) === port) return `${url.pathname}${url.search}${url.hash}`;
  } catch {
    // already relative
  }
  return location;
}

/** The previews phones have opened: token → port. */
export class Previews {
  private readonly ports = new Map<string, number>();

  /** A token for [port], the same one each time. */
  open(port: number): string {
    if (!Number.isInteger(port) || port < 1 || port > 65_535) throw new RangeError("Not a port.");
    for (const [token, open] of this.ports) if (open === port) return token;
    const token = randomBytes(24).toString("base64url");
    this.ports.set(token, port);
    return token;
  }

  close(port: number): void {
    for (const [token, open] of this.ports) if (open === port) this.ports.delete(token);
  }

  portFor(headers: IncomingHttpHeaders): number | null {
    const token = headers[PREVIEW_TOKEN_HEADER];
    return typeof token === "string" ? (this.ports.get(token) ?? null) : null;
  }

  /** Forwards one request; [path] is what follows `…/preview`. */
  forward(request: IncomingMessage, response: ServerResponse, path: string): void {
    const port = this.portFor(request.headers);
    if (port === null) {
      response.writeHead(403, { "content-type": "text/plain" });
      response.end("Open this preview from the Baya app.");
      return;
    }
    const upstream = httpRequest(
      {
        host: "localhost",
        port,
        method: request.method,
        path: path || "/",
        headers: upstreamHeaders(request.headers, port),
      },
      (reply) => {
        const headers: OutgoingHttpHeaders = {};
        for (const [name, value] of Object.entries(reply.headers)) {
          if (value === undefined || HOP_HEADERS.has(name)) continue;
          headers[name] = value;
        }
        if (typeof headers["location"] === "string") {
          headers["location"] = localRedirect(headers["location"], port);
        }
        response.writeHead(reply.statusCode ?? 502, reply.statusMessage, headers);
        reply.pipe(response);
      },
    );
    upstream.on("error", (error) => {
      if (response.headersSent) return response.destroy();
      response.writeHead(502, { "content-type": "text/plain" });
      response.end(`Nothing answered on port ${port}: ${error.message}`);
    });
    request.pipe(upstream);
  }

  /** Forwards a WebSocket (or other) upgrade to the preview's port. */
  upgrade(request: IncomingMessage, socket: Duplex, head: Buffer, path: string): void {
    const port = this.portFor(request.headers);
    if (port === null) return void socket.destroy();
    const headers = upstreamHeaders(request.headers, port);
    headers["connection"] = "Upgrade";
    headers["upgrade"] = request.headers["upgrade"] ?? "websocket";
    const upstream = httpRequest({
      host: "localhost",
      port,
      method: request.method,
      path: path || "/",
      headers,
    });
    upstream.on("upgrade", (reply, upstreamSocket, upstreamHead) => {
      const lines = [`HTTP/1.1 ${reply.statusCode} ${reply.statusMessage ?? ""}`];
      for (let i = 0; i < reply.rawHeaders.length; i += 2) {
        lines.push(`${reply.rawHeaders[i]}: ${reply.rawHeaders[i + 1]}`);
      }
      socket.write(`${lines.join("\r\n")}\r\n\r\n`);
      if (upstreamHead.length) socket.write(upstreamHead);
      if (head.length) upstreamSocket.write(head);
      upstreamSocket.pipe(socket).pipe(upstreamSocket);
      const end = () => {
        socket.destroy();
        upstreamSocket.destroy();
      };
      socket.on("error", end);
      upstreamSocket.on("error", end);
      socket.on("close", end);
      upstreamSocket.on("close", end);
    });
    upstream.on("response", (reply) => {
      // Refused: pass the answer on and hang up.
      socket.end(`HTTP/1.1 ${reply.statusCode} ${reply.statusMessage ?? ""}\r\n\r\n`);
    });
    upstream.on("error", () => socket.destroy());
    upstream.end();
  }
}

export const previews = new Previews();

// ── finding what is running ────────────────────────────────────────────────

/** Ports in `/proc/net/tcp{,6}` text listening where localhost reaches them. */
export function parseProcNet(text: string): number[] {
  const loopbackOrAny = new Set([
    "00000000",
    "0100007F",
    "00000000000000000000000000000000",
    "00000000000000000000000001000000",
    // ::ffff:127.0.0.1 and ::ffff:0.0.0.0
    "0000000000000000FFFF00000100007F",
    "0000000000000000FFFF000000000000",
  ]);
  const ports: number[] = [];
  for (const line of text.split("\n").slice(1)) {
    const fields = line.trim().split(/\s+/u);
    const [address, port] = (fields[1] ?? "").split(":");
    if (fields[3] !== "0A" || !address || !port) continue;
    if (loopbackOrAny.has(address.toUpperCase())) ports.push(Number.parseInt(port, 16));
  }
  return ports;
}

/** Ports in `netstat -ano` (Windows) or `lsof -nP -iTCP -sTCP:LISTEN -Fn` (macOS) output. */
export function parseListeners(text: string): number[] {
  const ports: number[] = [];
  for (const line of text.split(/\r?\n/u)) {
    // netstat: "  TCP    127.0.0.1:5173    0.0.0.0:0    LISTENING    1234"
    const netstat = /^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING/u.exec(line);
    // lsof -Fn: "n127.0.0.1:3000", "n*:3000", "n[::1]:3000"
    const lsof = /^n(\S+):(\d+)$/u.exec(line);
    const match = netstat ?? lsof;
    if (!match) continue;
    const address = match[1]!;
    const local = ["127.0.0.1", "0.0.0.0", "[::]", "[::1]", "*", "::", "::1"].includes(address);
    if (local) ports.push(Number(match[2]));
  }
  return ports;
}

async function listeningPorts(): Promise<number[]> {
  if (process.platform === "linux") {
    const texts = await Promise.all(
      ["/proc/net/tcp", "/proc/net/tcp6"].map((file) => readFile(file, "utf8").catch(() => "")),
    );
    return texts.flatMap(parseProcNet);
  }
  const [command, args] =
    process.platform === "win32"
      ? ["netstat", ["-ano", "-p", "TCP"]]
      : ["lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fn"]];
  try {
    const { stdout } = await run(command, args, { windowsHide: true, timeout: 8_000 });
    let ports = parseListeners(stdout);
    if (process.platform === "win32") {
      const v6 = await run("netstat", ["-ano", "-p", "TCPv6"], {
        windowsHide: true,
        timeout: 8_000,
      });
      ports = ports.concat(parseListeners(v6.stdout));
    }
    return ports;
  } catch {
    return [];
  }
}

/** The `<title>` of an HTML page, or "". */
export function pageTitle(html: string): string {
  const match = /<title[^>]*>([^<]*)<\/title>/iu.exec(html);
  return (match?.[1] ?? "")
    .replace(/&amp;/gu, "&")
    .replace(/&lt;/gu, "<")
    .replace(/&gt;/gu, ">")
    .replace(/&quot;/gu, '"')
    .replace(/&#39;/gu, "'")
    .replace(/\s+/gu, " ")
    .trim();
}

/** Asks [port] for `/`; null when it does not answer HTTP. */
function probe(port: number): Promise<PreviewPort | null> {
  return new Promise((resolve) => {
    const request = httpRequest(
      {
        host: "localhost",
        port,
        path: "/",
        method: "GET",
        timeout: 1_500,
        headers: { accept: "text/html" },
      },
      (reply) => {
        const html = String(reply.headers["content-type"] ?? "").includes("html");
        let body = "";
        reply.setEncoding("utf8");
        reply.on("data", (chunk: string) => {
          body += chunk;
          if (body.length > 64 * 1024) reply.destroy();
        });
        const done = () =>
          resolve({
            port,
            status: reply.statusCode ?? 0,
            title: html ? pageTitle(body) : "",
            html,
          });
        reply.on("end", done);
        reply.on("close", done);
      },
    );
    request.on("timeout", () => request.destroy());
    request.on("error", () => resolve(null));
    request.end();
  });
}

/**
 * Web servers on this computer a phone might want to see: ports from 1024
 * up listening on loopback or every interface that answer HTTP, web pages
 * first. [exclude] are Baya's own.
 */
export async function previewPorts(exclude: Iterable<number> = []): Promise<PreviewPort[]> {
  const skip = new Set(exclude);
  const ports = [...new Set(await listeningPorts())]
    .filter((port) => port >= 1024 && !skip.has(port))
    .sort((a, b) => a - b)
    .slice(0, 64);
  const found = (await Promise.all(ports.map(probe))).filter((port) => port !== null);
  return found.sort((a, b) => Number(b.html) - Number(a.html) || a.port - b.port);
}
