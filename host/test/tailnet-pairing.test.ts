import { describe, expect, test } from "vitest";
import { TailnetPairingServer } from "../src/tailnet/pairing_server.ts";

const self = { ip: "127.0.0.1", dnsName: "box.tail.ts.net", name: "box", userId: 42 };

async function serve(callerUser: number | null) {
  let issued = 0;
  const server = new TailnetPairingServer(
    async () => `baya://pair?n=${++issued}`,
    async () => callerUser,
  );
  const port = 20_000 + Math.floor(Math.random() * 20_000);
  await server.start(self, port);
  return { server, url: `http://127.0.0.1:${port}` };
}

describe("Tailscale pairing endpoint", () => {
  test("hands a pairing code to the owner's own devices", async () => {
    const { server, url } = await serve(42);
    try {
      const response = await fetch(`${url}/pair`);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ uri: "baya://pair?n=1", name: "box" });
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
      } finally {
        server.close();
      }
    }
  });
});
