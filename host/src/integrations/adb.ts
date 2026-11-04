/**
 * The phone as an Android device for the computer's agents: Baya pairs and
 * connects the computer's `adb` with the phone's Wireless debugging over
 * the tailnet, after which any agent can run `adb` against it.
 */
import { execFile } from "node:child_process";
import { readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { RpcError } from "../acp/jsonrpc.ts";
import { findExecutable } from "../workspace/directories.ts";

const run = promisify(execFile);
const ADDRESS = /^[0-9A-Za-z.:[\]-]+:\d{1,5}$/u;

/** Platform-tools' `adb`: on PATH, in an Android SDK, or a Scoop app. */
export async function findAdb(env: NodeJS.ProcessEnv = process.env): Promise<string | null> {
  const onPath = await findExecutable("adb");
  if (onPath) return onPath;
  const exe = process.platform === "win32" || env["WSL_DISTRO_NAME"] ? ".exe" : "";
  const sdks = [
    env["ANDROID_HOME"],
    env["ANDROID_SDK_ROOT"],
    process.platform === "win32" && env["LOCALAPPDATA"]
      ? join(env["LOCALAPPDATA"], "Android", "Sdk")
      : undefined,
    process.platform === "darwin" ? join(homedir(), "Library", "Android", "sdk") : undefined,
    join(homedir(), "Android", "Sdk"),
  ].filter((dir): dir is string => Boolean(dir));
  const scoops = [
    env["SCOOP"],
    env["SCOOP_GLOBAL"],
    join(homedir(), "scoop"),
    "C:\\Scoop",
    "/mnt/c/Scoop",
  ]
    .filter((dir): dir is string => Boolean(dir))
    .map((dir) => join(dir, "apps"));
  for (const apps of scoops) {
    try {
      for (const app of await readdir(apps)) {
        sdks.push(join(apps, app, "current"));
      }
    } catch {
      // No Scoop there.
    }
  }
  for (const sdk of sdks) {
    for (const candidate of [join(sdk, "platform-tools", `adb${exe}`), join(sdk, `adb${exe}`)]) {
      const found = await findExecutable(candidate);
      if (found) return found;
    }
  }
  return null;
}

async function adb(...args: string[]): Promise<string> {
  const path = await findAdb();
  if (!path) {
    throw new RpcError(-32000, "This computer has no adb. Install Android platform-tools.", {
      reason: "no_adb",
    });
  }
  try {
    const { stdout, stderr } = await run(path, args, { timeout: 30_000, windowsHide: true });
    return `${stdout}${stderr}`.trim();
  } catch (error) {
    const output = error as { stdout?: string; stderr?: string; message: string };
    throw new Error(`${output.stdout ?? ""}${output.stderr ?? ""}`.trim() || output.message);
  }
}

function address(value: unknown): string {
  if (typeof value !== "string" || !ADDRESS.test(value)) {
    throw RpcError.invalidParams("An address is ip:port.");
  }
  return value;
}

export interface AdbDevice {
  serial: string;
  state: string;
}

/** `adb devices`: what the computer's adb sees, and whether there is one. */
export async function adbStatus(): Promise<{ adb: string | null; devices: AdbDevice[] }> {
  const path = await findAdb();
  if (!path) return { adb: null, devices: [] };
  const listed = await adb("devices");
  const devices = listed
    .split(/\r?\n/u)
    .slice(1)
    .map((line) => line.trim().split(/\s+/u))
    .filter((parts) => parts.length >= 2 && parts[0])
    .map(([serial, state]) => ({ serial: serial!, state: state! }));
  return { adb: path, devices };
}

/** `adb pair <address> <code>`, the six digits Wireless debugging shows. */
export async function adbPair(target: unknown, code: unknown): Promise<{ output: string }> {
  if (typeof code !== "string" || !/^\d{6}$/u.test(code)) {
    throw RpcError.invalidParams("The pairing code is six digits.");
  }
  const output = await adb("pair", address(target), code);
  if (!/Successfully paired/iu.test(output)) throw new Error(output || "Pairing failed.");
  return { output };
}

/** `adb connect <address>`; the device must then show as `device`. */
export async function adbConnect(target: unknown): Promise<{ serial: string; output: string }> {
  const serial = address(target);
  const output = await adb("connect", serial);
  if (!/connected to/iu.test(output) || /failed|unable|cannot/iu.test(output)) {
    throw new Error(output || "Could not connect.");
  }
  const { devices } = await adbStatus();
  const state = devices.find((device) => device.serial === serial)?.state;
  if (state !== "device") {
    throw new Error(
      state === "unauthorized"
        ? "The phone has not allowed this computer yet. Pair it first."
        : `The phone is ${state ?? "not listed"}.`,
    );
  }
  return { serial, output };
}

export async function adbDisconnect(target: unknown): Promise<{ output: string }> {
  return { output: await adb("disconnect", address(target)) };
}
