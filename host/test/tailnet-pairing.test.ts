import { describe, expect, test } from "vitest";
import { type HostInfo, TailnetPairingServer } from "../src/tailnet/pairing_server.ts";

const self = { dnsName: "box.tail.ts.net", name: "box", login: "me@github" };
const info: HostInfo = { label: "windows", name: "BOX (Windows)", key: "a2V5" };

describe("Tailscale endpoint", () => {
  test("serves this host's own path to the owner's devices only", async () => {
    let issued = 0;
    const server = new TailnetPairingServer(info, async () => `baya://pair?n=${++issued}`);
    const port = 20_000 + Math.floor(Math.random() * 20_000);
    await server.start(self, port);
    const url = `http://127.0.0.1:${port}/baya-pair`;
    const as = (login: string) => ({ headers: { "Tailscale-User-Login": login } });
    try {
      const described = await fetch(`${url}/windows/info`, as("me@github"));
      expect(await described.json()).toEqual(info);
      const paired = await fetch(`${url}/windows/pair`, as("me@github"));
      expect(await paired.json()).toEqual({ uri: "baya://pair?n=1", ...info });
      expect((await fetch(`${url}/windows/pair`, as("someone@github"))).status).toBe(403);
      expect((await fetch(`${url}/windows/info`)).status).toBe(403);
      expect((await fetch(`${url}/wsl/info`, as("me@github"))).status).toBe(404);
      expect((await fetch(`${url}/info`, as("me@github"))).status).toBe(404);
    } finally {
      server.close();
    }
  });
});
