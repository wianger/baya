import { describe, expect, test } from "vitest";
import { type HostInfo, TailnetPairingServer } from "../src/tailnet/pairing_server.ts";

const self = {
  ip: "127.0.0.1",
  dnsName: "box.tail.ts.net",
  name: "box",
  userId: 42,
  login: "me@github",
};
const info: HostInfo = { label: "windows", name: "BOX (Windows)", key: "a2V5" };

async function serve(callerUser: number | null) {
  let issued = 0;
  const server = new TailnetPairingServer(
    info,
    async () => `baya://pair?n=${++issued}`,
    async () => callerUser,
  );
  const port = 20_000 + Math.floor(Math.random() * 20_000);
  await server.start(self, port);
  return { server, url: `http://127.0.0.1:${port}` };
}

describe("Tailscale pairing endpoint", () => {
  test("describes itself and issues codes to the owner's devices", async () => {
    const { server, url } = await serve(42);
    try {
      expect(await (await fetch(`${url}/info`)).json()).toEqual(info);
      const response = await fetch(`${url}/pair`);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ uri: "baya://pair?n=1", ...info });
      expect((await fetch(`${url}/other`)).status).toBe(404);
    } finally {
      server.close();
    }
  });

  test("refuses devices of other Tailscale users", async () => {
    for (const user of [7, null]) {
      const { server, url } = await serve(user);
      try {
        expect((await fetch(`${url}/pair`)).status).toBe(403);
        expect((await fetch(`${url}/info`)).status).toBe(403);
      } finally {
        server.close();
      }
    }
  });

  test("through tailscale serve: its own label path, the login header, and the legacy path", async () => {
    const { server, url } = await serve(null);
    const as = (login: string) => ({ headers: { "Tailscale-User-Login": login } });
    try {
      expect((await fetch(`${url}/baya-pair/windows/info`, as("me@github"))).status).toBe(200);
      expect((await fetch(`${url}/baya-pair/wsl/info`, as("me@github"))).status).toBe(404);
      expect((await fetch(`${url}/baya-pair/info`, as("me@github"))).status).toBe(200);
      expect((await fetch(`${url}/baya-pair/windows/pair`, as("someone@github"))).status).toBe(403);
      expect((await fetch(`${url}/baya-pair/windows/pair`, as("me@github"))).status).toBe(200);
    } finally {
      server.close();
    }
  });
});
