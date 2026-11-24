/**
 * Sunshine on this computer, run for the phone: the host that streams the
 * screen to Baya's Moonlight core (the GameStream protocol: hardware
 * encoding, RTP with FEC over UDP, tens of milliseconds end to end).
 *
 * Baya owns Sunshine's web account: it sets one on a fresh install and
 * keeps it in ~/.baya/sunshine.json, then completes a phone's pairing by
 * handing Sunshine the PIN the phone made up, so nobody types one.
 */

import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { request } from "node:https";
import { join } from "node:path";
import { BAYA_HOME, ensureBayaHome } from "../config.ts";

const API = { host: "127.0.0.1", port: 47990 };
const EXECUTABLE = "C:\\Program Files\\Sunshine\\sunshine.exe";

interface Account {
  username: string;
  password: string;
}

export type SunshineState =
  | { ready: true }
  | { ready: false; reason: "not_windows" | "not_installed" | "not_running" | "foreign_account" };

const accountPath = () => join(BAYA_HOME, "sunshine.json");

function readAccount(): Account | null {
  try {
    const value = JSON.parse(readFileSync(accountPath(), "utf8")) as Partial<Account>;
    return typeof value.username === "string" && typeof value.password === "string"
      ? { username: value.username, password: value.password }
      : null;
  } catch {
    return null;
  }
}

/** Sunshine's web API on this computer; its certificate is its own, self-signed. */
function api(
  method: "GET" | "POST",
  path: string,
  options: { account?: Account | null; body?: unknown } = {},
): Promise<{ status: number; json: Record<string, unknown> | null }> {
  return new Promise((resolve, reject) => {
    const body = options.body === undefined ? undefined : JSON.stringify(options.body);
    const account = options.account;
    const req = request(
      {
        ...API,
        method,
        path,
        rejectUnauthorized: false,
        timeout: 5000,
        headers: {
          ...(body
            ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) }
            : {}),
          ...(account
            ? {
                Authorization: `Basic ${Buffer.from(`${account.username}:${account.password}`).toString("base64")}`,
              }
            : {}),
        },
      },
      (res) => {
        let text = "";
        res.setEncoding("utf8");
        res.on("data", (chunk: string) => {
          text += chunk;
        });
        res.on("end", () => {
          let json: Record<string, unknown> | null = null;
          try {
            json = JSON.parse(text) as Record<string, unknown>;
          } catch {
            json = null;
          }
          resolve({ status: res.statusCode ?? 0, json });
        });
      },
    );
    req.on("timeout", () => req.destroy(new Error("Sunshine did not answer.")));
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

/**
 * Whether Sunshine can stream this screen now, setting Baya's account on
 * a fresh install.
 */
export async function sunshineState(): Promise<SunshineState> {
  if (process.platform !== "win32") return { ready: false, reason: "not_windows" };
  if (!existsSync(EXECUTABLE)) return { ready: false, reason: "not_installed" };
  let account = readAccount();
  let probe: Awaited<ReturnType<typeof api>>;
  try {
    probe = await api("GET", "/api/pin", { account });
  } catch {
    return { ready: false, reason: "not_running" };
  }
  if (probe.status === 200) return { ready: true };
  // A fresh install sends everything to /welcome until an account exists.
  if (probe.status === 307 || probe.status === 302) {
    const created = { username: "baya", password: randomBytes(18).toString("base64url") };
    const set = await api("POST", "/api/password", {
      body: {
        newUsername: created.username,
        newPassword: created.password,
        confirmNewPassword: created.password,
      },
    });
    if (set.status === 200 && set.json?.["status"] === true) {
      ensureBayaHome();
      writeFileSync(accountPath(), `${JSON.stringify(created, null, 2)}\n`, { mode: 0o600 });
      account = created;
      return (await api("GET", "/api/pin", { account })).status === 200
        ? { ready: true }
        : { ready: false, reason: "foreign_account" };
    }
  }
  // Someone set Sunshine up by hand: `baya remote login` takes that account.
  return { ready: false, reason: "foreign_account" };
}

/** Keeps an account someone set in Sunshine's web UI, after checking it. */
export async function sunshineLogin(username: string, password: string): Promise<boolean> {
  const account = { username, password };
  if ((await api("GET", "/api/pin", { account })).status !== 200) return false;
  ensureBayaHome();
  writeFileSync(accountPath(), `${JSON.stringify(account, null, 2)}\n`, { mode: 0o600 });
  return true;
}

/**
 * Completes a phone's pairing with [pin]: the phone asked Sunshine to pair
 * a moment ago, and its request waits in Sunshine's list until then.
 */
export async function sunshinePin(pin: string, name: string, timeoutMs = 20_000): Promise<void> {
  if (!/^\d{4}$/u.test(pin)) throw new Error("A pairing PIN is four digits.");
  const account = readAccount();
  if (!account) throw new Error("Baya has no Sunshine account here yet.");
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    const pending = await api("GET", "/api/pin", { account });
    const pairings = Array.isArray(pending.json?.["pairings"])
      ? (pending.json["pairings"] as Array<Record<string, unknown>>)
      : [];
    const newest = pairings.at(-1);
    const id = newest?.["pairing_id"] ?? newest?.["id"];
    if (typeof id === "string") {
      const done = await api("POST", "/api/pin", {
        account,
        body: { pairing_id: id, pin, name: name.slice(0, 64) || "Baya" },
      });
      if (done.status === 200 && done.json?.["status"] !== false) return;
      throw new Error(`Sunshine refused the PIN (${String(done.json?.["error"] ?? done.status)}).`);
    }
    await new Promise((resolve) => setTimeout(resolve, 400));
  }
  throw new Error("The phone's pairing request did not reach Sunshine.");
}
