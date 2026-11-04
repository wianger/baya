/**
 * Once this computer's adb is connected to the phone, every agent session
 * started from then on gets the phone as MCP tools: mobile-mcp (pinned,
 * installed under ~/.baya/tools, telemetry off) gives agents the screen as
 * a structured accessibility tree with taps, swipes, typing and app
 * launches, rather than raw adb alone.
 */
import { execFile } from "node:child_process";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { mkdir, symlink, unlink } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";
import { BAYA_HOME, ensureBayaHome } from "../config.ts";
import { spawnPlan } from "../process/spawn.ts";
import { findExecutable } from "../workspace/directories.ts";
import { findAdb } from "./adb.ts";

const run = promisify(execFile);
const PACKAGE = "@mobilenext/mobile-mcp";
const VERSION = "1.0.16";

const toolsDir = () => join(BAYA_HOME, "tools", "mobile-mcp");
const entry = () =>
  join(toolsDir(), "node_modules", "@mobilenext", "mobile-mcp", "lib", "index.js");
const phoneFile = () => join(BAYA_HOME, "phone.json");

/** The phone adb is connected to, as `adb -s` names it; null when none. */
export function connectedPhone(): string | null {
  try {
    const serial = JSON.parse(readFileSync(phoneFile(), "utf8"))["serial"];
    return typeof serial === "string" ? serial : null;
  } catch {
    return null;
  }
}

export function rememberPhone(serial: string | null): void {
  if (serial === null) {
    rmSync(phoneFile(), { force: true });
    return;
  }
  ensureBayaHome();
  writeFileSync(phoneFile(), `${JSON.stringify({ serial })}\n`);
}

/** Whether the phone tools are installed. */
export function phoneToolsReady(): boolean {
  return existsSync(entry());
}

/** Installs the pinned mobile-mcp once; false when npm can't. */
export async function installPhoneTools(): Promise<boolean> {
  const marker = join(toolsDir(), ".version");
  if (existsSync(entry()) && existsSync(marker) && readFileSync(marker, "utf8") === VERSION) {
    return true;
  }
  await mkdir(toolsDir(), { recursive: true });
  const plan = spawnPlan("npm", [
    "install",
    "--prefix",
    toolsDir(),
    "--no-audit",
    "--no-fund",
    "--loglevel=error",
    `${PACKAGE}@${VERSION}`,
  ]);
  try {
    await run(plan.command, plan.prefixArgs, {
      timeout: 300_000,
      windowsHide: true,
      windowsVerbatimArguments: plan.windowsVerbatimArguments,
    });
  } catch {
    return false;
  }
  if (!existsSync(entry())) return false;
  writeFileSync(marker, VERSION);
  return true;
}

/**
 * The ANDROID_HOME mobile-mcp looks in: it runs `<home>/platform-tools/adb`.
 * An adb elsewhere (or a Windows adb.exe seen from WSL) gets a link there.
 */
async function androidHome(adb: string): Promise<string> {
  const dir = dirname(adb);
  const name = basename(adb).toLowerCase();
  if (basename(dir) === "platform-tools" && (process.platform === "win32" || name === "adb")) {
    return dirname(dir);
  }
  const home = join(BAYA_HOME, "tools", "android");
  const link = join(home, "platform-tools", process.platform === "win32" ? "adb.exe" : "adb");
  await mkdir(dirname(link), { recursive: true });
  await unlink(link).catch(() => {});
  await symlink(adb, link);
  return home;
}

/** ACP `McpServer`s for a new agent session: the phone, when connected. */
export async function phoneMcpServers(): Promise<unknown[]> {
  if (!connectedPhone() || !existsSync(entry())) return [];
  const [node, adb] = await Promise.all([findExecutable("node"), findAdb()]);
  if (!node || !adb) return [];
  try {
    return [
      {
        name: "phone",
        command: node,
        args: [entry()],
        env: [
          { name: "ANDROID_HOME", value: await androidHome(adb) },
          { name: "MOBILEMCP_DISABLE_TELEMETRY", value: "1" },
        ],
      },
    ];
  } catch {
    return [];
  }
}
