import { once } from "node:events";
import { createServer, request, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, test } from "vitest";
import { WebSocket, WebSocketServer } from "ws";
import {
  localRedirect,
  PREVIEW_TOKEN_HEADER,
  Previews,
  pageTitle,
  parseListeners,
  parseProcNet,
  upstreamHeaders,
} from "../src/preview/preview.ts";

const servers: Server[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) {
    server.closeAllConnections();
    await new Promise((done) => server.close(done));
  }
});

async function listen(server: Server): Promise<number> {
  servers.push(server);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return (server.address() as AddressInfo).port;
}

describe("finding web servers", () => {
  test("reads listening loopback and wildcard ports from /proc/net/tcp", () => {
    const tcp = [
      "  sl  local_address rem_address   st tx_queue rx_queue",
      "   0: 0100007F:1435 00000000:0000 0A 00000000:00000000",
      "   1: 00000000:0BB8 00000000:0000 0A 00000000:00000000",
      "   2: 0100007F:1F90 0100007F:9C40 01 00000000:00000000",
      "   3: 6401A8C0:22B8 00000000:0000 0A 00000000:00000000",
    ].join("\n");
    expect(parseProcNet(tcp)).toEqual([5173, 3000]);
    const tcp6 = [
      "  sl  local_address                         remote_address",
      "   0: 00000000000000000000000001000000:1F40 00000000000000000000000000000000:0000 0A",
    ].join("\n");
    expect(parseProcNet(tcp6)).toEqual([8000]);
  });

  test("reads netstat and lsof output", () => {
    const netstat = [
      "  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1220",
      "  TCP    127.0.0.1:5173         0.0.0.0:0              LISTENING       4412",
      "  TCP    192.168.1.5:139        0.0.0.0:0              LISTENING       4",
      "  TCP    127.0.0.1:5173         127.0.0.1:50000        ESTABLISHED     4412",
      "  TCP    [::1]:3000             [::]:0                 LISTENING       9",
    ].join("\r\n");
    expect(parseListeners(netstat)).toEqual([135, 5173, 3000]);
    expect(parseListeners("p123\nn127.0.0.1:4321\nn*:8080\nn10.0.0.2:9999\n")).toEqual([
      4321, 8080,
    ]);
  });

  test("takes a page's title", () => {
    expect(pageTitle("<html><head><title> Vite &amp; React\n</title>")).toBe("Vite & React");
    expect(pageTitle("<p>no title</p>")).toBe("");
  });
});

describe("forwarding", () => {
  test("rewrites headers as a local browser would send them", () => {
    const headers = upstreamHeaders(
      {
        host: "box.tail1.ts.net",
        origin: "https://box.tail1.ts.net",
        referer: "https://box.tail1.ts.net/baya-pair/wsl/preview/app?x=1",
        "tailscale-user-login": "me@github",
        "x-forwarded-host": "box.tail1.ts.net",
        [PREVIEW_TOKEN_HEADER]: "secret",
        accept: "text/html",
      },
      5173,
    );
    expect(headers).toEqual({
      host: "localhost:5173",
      origin: "http://localhost:5173",
      referer: "http://localhost:5173/baya-pair/wsl/preview/app?x=1",
      accept: "text/html",
    });
    expect(localRedirect("http://localhost:5173/login?next=/", 5173)).toBe("/login?next=/");
    expect(localRedirect("https://github.com/login", 5173)).toBe("https://github.com/login");
    expect(localRedirect("/relative", 5173)).toBe("/relative");
  });

  test("forwards an opened port's requests and refuses others", async () => {
    const site = createServer((req, res) => {
      res.writeHead(req.url === "/old" ? 302 : 200, {
        "content-type": "text/plain",
        ...(req.url === "/old" ? { location: `http://localhost:${sitePort}/new` } : {}),
      });
      res.end(`${req.method} ${req.url} host=${req.headers.host}`);
    });
    const sitePort = await listen(site);
    const previews = new Previews();
    const token = previews.open(sitePort);
    expect(previews.open(sitePort)).toBe(token);
    const front = createServer((req, res) => previews.forward(req, res, req.url ?? "/"));
    const frontPort = await listen(front);

    const get = (path: string, headers: Record<string, string>) =>
      new Promise<{ status: number; body: string; location: string | undefined }>((done, fail) => {
        const req = request({ host: "127.0.0.1", port: frontPort, path, headers }, (res) => {
          let body = "";
          res.on("data", (chunk) => {
            body += chunk;
          });
          res.on("end", () =>
            done({ status: res.statusCode ?? 0, body, location: res.headers.location }),
          );
        });
        req.on("error", fail);
        req.end();
      });

    const ok = await get("/src/main.ts?v=1", { [PREVIEW_TOKEN_HEADER]: token });
    expect(ok.status).toBe(200);
    expect(ok.body).toBe(`GET /src/main.ts?v=1 host=localhost:${sitePort}`);
    const moved = await get("/old", { [PREVIEW_TOKEN_HEADER]: token });
    expect(moved.location).toBe("/new");
    expect((await get("/", {})).status).toBe(403);
    expect((await get("/", { [PREVIEW_TOKEN_HEADER]: "guess" })).status).toBe(403);
    previews.close(sitePort);
    expect((await get("/", { [PREVIEW_TOKEN_HEADER]: token })).status).toBe(403);
  });

  test("carries WebSockets through, for hot reload", async () => {
    const site = createServer();
    const wss = new WebSocketServer({ server: site });
    wss.on("connection", (socket, req) => {
      socket.on("message", (data) => socket.send(`${req.headers.origin} ${String(data)}`));
    });
    const sitePort = await listen(site);
    const previews = new Previews();
    const token = previews.open(sitePort);
    const front = createServer();
    front.on("upgrade", (req, socket, head) => previews.upgrade(req, socket, head, req.url ?? "/"));
    const frontPort = await listen(front);

    const client = new WebSocket(`ws://127.0.0.1:${frontPort}/hmr`, {
      headers: { [PREVIEW_TOKEN_HEADER]: token, origin: "https://box.ts.net" },
    });
    await once(client, "open");
    client.send("ping");
    const [reply] = await once(client, "message");
    expect(String(reply)).toBe(`http://localhost:${sitePort} ping`);
    client.close();
    wss.close();
  });
});
