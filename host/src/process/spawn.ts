import { type ChildProcess, execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";

export interface SpawnTarget {
  command: string;
  prefixArgs: string[];
}

export interface SpawnPlan extends SpawnTarget {
  shellWrapper: boolean;
  windowsVerbatimArguments: boolean;
}

const WINDOWS_EXECUTABLE_EXTENSIONS = [".exe", ".cmd", ".bat", ".com"];

function quotedWindowsCommand(command: string, args: string[]): string {
  return [
    `"${command.replace(/"/g, '""')}"`,
    ...args.map((arg) => (/[\s"]/u.test(arg) ? `"${arg.replace(/"/g, '""')}"` : arg)),
  ].join(" ");
}

export function resolveExecutable(
  executable: string,
  platform: NodeJS.Platform = process.platform,
): string {
  if (platform !== "win32") return executable;
  if (executable.includes("\\") || executable.includes("/") || /\.[a-z0-9]+$/iu.test(executable)) {
    return executable;
  }
  try {
    const matches = execFileSync("where", [executable], { encoding: "utf8" })
      .split(/\r?\n/u)
      .map((line) => line.trim())
      .filter(Boolean);
    return (
      matches.find((match) =>
        WINDOWS_EXECUTABLE_EXTENSIONS.some((extension) => match.toLowerCase().endsWith(extension)),
      ) ??
      matches[0] ??
      executable
    );
  } catch {
    return executable;
  }
}

function managedInstallerTarget(commandPath: string): string | null {
  try {
    if (!/"%~dp0pi-launcher\.js"/iu.test(readFileSync(commandPath, "utf8"))) return null;
    const install = join(dirname(dirname(commandPath)), "install");
    const version = readFileSync(join(install, "current-version"), "utf8").trim();
    if (!version || version === "." || version === ".." || !/^[0-9A-Za-z._+-]+$/u.test(version)) {
      return null;
    }
    const root = join(
      install,
      "releases",
      version,
      "node_modules",
      "@earendil-works",
      "pi-coding-agent",
    );
    const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as {
      bin?: string | { pi?: string };
    };
    const bin = typeof pkg.bin === "string" ? pkg.bin : pkg.bin?.pi;
    if (typeof bin !== "string") return null;
    const target = resolve(root, bin);
    const rel = relative(root, target);
    return !rel.startsWith("..") && !isAbsolute(rel) && existsSync(target) ? target : null;
  } catch {
    return null;
  }
}

function npmShimTarget(commandPath: string): string | null {
  try {
    const content = readFileSync(commandPath, "utf8");
    const match = content.match(/"%dp0%\\([^"]+\.[cm]?js)"/iu);
    if (!match?.[1]) return null;
    const target = join(dirname(commandPath), match[1]);
    return existsSync(target) ? target : null;
  } catch {
    return null;
  }
}

export function resolveSpawnTarget(
  executable: string,
  platform: NodeJS.Platform = process.platform,
  nodeExecutable = process.execPath,
): SpawnTarget {
  const resolved = resolveExecutable(executable, platform);
  if (platform !== "win32" || !/\.(cmd|bat)$/iu.test(resolved)) {
    return { command: resolved, prefixArgs: [] };
  }
  const jsTarget = managedInstallerTarget(resolved) ?? npmShimTarget(resolved);
  return jsTarget
    ? { command: nodeExecutable, prefixArgs: [jsTarget] }
    : { command: resolved, prefixArgs: [] };
}

export function spawnPlan(
  executable: string,
  args: string[],
  platform: NodeJS.Platform = process.platform,
  comSpec = process.env["ComSpec"]?.trim() || "cmd.exe",
): SpawnPlan {
  const target = resolveSpawnTarget(executable, platform);
  const allArgs = [...target.prefixArgs, ...args];
  if (platform === "win32" && /\.(cmd|bat)$/iu.test(target.command)) {
    const line = quotedWindowsCommand(target.command, allArgs);
    return {
      command: comSpec,
      prefixArgs: ["/d", "/s", "/c", `"${line}"`],
      shellWrapper: true,
      windowsVerbatimArguments: true,
    };
  }
  return {
    command: target.command,
    prefixArgs: allArgs,
    shellWrapper: false,
    windowsVerbatimArguments: false,
  };
}

export function terminateChild(child: ChildProcess | null): void {
  if (!child || child.killed) return;
  try {
    child.kill("SIGTERM");
  } catch {
    // The process may already have exited.
  }
}
