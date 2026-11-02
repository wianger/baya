#!/usr/bin/env node
import { spawn } from "node:child_process";
import { closeSync, mkdirSync, openSync } from "node:fs";
import { hostname } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { booleanFlag, type ParsedArgs, parseArgs, stringFlag } from "./cli/args.ts";
import {
  BAYA_HOME,
  ensureBayaHome,
  loadConfig,
  resolveRelayUrl,
  saveConfig,
  validateRelayUrl,
} from "./config.ts";
import { controlCall, readControlInfo } from "./control/client.ts";
import { ControlServer } from "./control/server.ts";
import { BayaManager } from "./host/manager.ts";
import { roomIdForBayaSession } from "./host/session_host.ts";
import { buildQRUri, displayQR } from "./pairing/qr.ts";
import { getOrCreateEd25519Keypair, listPeers, removePeers } from "./pairing/storage.ts";
import { packageVersion } from "./runtime/version.ts";
import { installStartup, uninstallStartup } from "./service.ts";
import { findSession, listSessions, removeSession } from "./session/registry.ts";
import { workspaceAgentDefinition } from "./workspace/agents.ts";
import { availableAgents, resolveDirectory } from "./workspace/directories.ts";
import type { WorkspaceAgent } from "./workspace/types.ts";

interface StatusResult {
  pid: number;
  sessions: Array<{
    id: string;
    name: string;
    cwd: string;
    agent: WorkspaceAgent;
    online: boolean;
    busy: boolean;
    room_id: string;
  }>;
}

function flag(args: ParsedArgs, name: string): string | undefined {
  return stringFlag(args, name);
}

function jsonFlag(args: ParsedArgs): boolean {
  return booleanFlag(args, "json");
}

function agentFlag(args: ParsedArgs): WorkspaceAgent | undefined {
  const value = flag(args, "agent");
  if (value === undefined) return undefined;
  const definition = workspaceAgentDefinition(value);
  if (!definition) {
    throw new Error("Agent must be one of: pi, codex, deepseek.");
  }
  return definition.id;
}

function printHelp(): void {
  process.stdout.write(`Baya ${packageVersion()}

Usage:
  baya                    Start the host in this folder
  baya serve              Run the resident host in the foreground
  baya start              Start the resident host in the background
  baya stop               Stop the resident host
  baya status             Show host and session status
  baya sessions           List registered sessions
  baya new [path]         Register a new session (default agent: pi)
  baya open <path>        Open a workspace on a running host
  baya remove <id>        Remove a session
  baya pair [id]          Print a pairing QR for this host
  baya devices            List paired phones
  baya unpair <name|key>  Revoke a paired phone
  baya agents             Detect installed Pi, Codex, and DeepSeek
  baya doctor             Diagnose relay, identity, and agents
  baya set-relay <url>    Save the relay URL
  baya install-service    Start Baya at login (Windows, systemd, launchd; no admin)
  baya uninstall-service  Remove login startup

Options:
  --agent <pi|codex|deepseek>  Agent for a new session
  --name <name>                Display name for a session
  --cwd <path>                 Folder for foreground host startup
  --ttl <seconds>              Pairing code lifetime (10-600 seconds)
  --json                       Machine-readable output
`);
}

function print(value: unknown, json: boolean): void {
  process.stdout.write(json ? `${JSON.stringify(value, null, 2)}\n` : human(value));
}

function human(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return `${value}\n`;
  if (Array.isArray(value)) return value.map(human).join("");
  if (typeof value === "object") {
    const record = value as Record<string, unknown>;
    if (Array.isArray(record["sessions"])) {
      const sessions = record["sessions"] as StatusResult["sessions"];
      if (sessions.length === 0) return "No Baya sessions are registered.\n";
      return sessions
        .map(
          (session) =>
            `${session.online ? (session.busy ? "●" : "○") : "×"} ${session.name}  ` +
            `${session.agent}  ${session.cwd}  ${session.id}\n`,
        )
        .join("");
    }
    return `${JSON.stringify(value, null, 2)}\n`;
  }
  return `${String(value)}\n`;
}

async function controlOnline(): Promise<StatusResult | null> {
  try {
    return await controlCall<StatusResult>("status", undefined, 1_500);
  } catch {
    return null;
  }
}

async function startBackground(args: ParsedArgs): Promise<StatusResult> {
  const current = await controlOnline();
  if (current) return current;

  ensureBayaHome();
  const runtime = join(BAYA_HOME, "runtime");
  const logs = join(BAYA_HOME, "logs");
  mkdirSync(runtime, { recursive: true, mode: 0o700 });
  mkdirSync(logs, { recursive: true, mode: 0o700 });
  const logPath = join(logs, "host.log");
  const log = openSync(logPath, "a", 0o600);
  const entry = fileURLToPath(import.meta.url);
  const serveArgs = [entry, "serve"];
  const cwdValue = flag(args, "cwd");
  const cwd = cwdValue ? await resolveDirectory(resolve(cwdValue)) : undefined;
  const agent = agentFlag(args);
  const name = flag(args, "name");
  if (cwd) serveArgs.push("--cwd", resolve(cwd));
  if (agent) serveArgs.push("--agent", agent);
  if (name) serveArgs.push("--name", name);
  try {
    const child = spawn(process.execPath, serveArgs, {
      detached: true,
      env: { ...process.env },
      stdio: ["ignore", log, log],
      windowsHide: true,
    });
    child.unref();
  } finally {
    closeSync(log);
  }

  for (let attempt = 0; attempt < 75; attempt++) {
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 200));
    const status = await controlOnline();
    if (status) return status;
  }
  throw new Error(`Baya did not start. Check ${logPath}.`);
}

async function runForeground(args: ParsedArgs): Promise<void> {
  const currentInfo = readControlInfo();
  if (currentInfo) {
    const current = await controlOnline();
    if (current) {
      throw new Error(`Baya is already running with PID ${current.pid}.`);
    }
  }

  const manager = new BayaManager();
  let control: ControlServer | null = null;
  let stopping = false;
  const shutdown = async (code = 0): Promise<void> => {
    if (stopping) return;
    stopping = true;
    await control?.close();
    await manager.stop();
    process.exit(code);
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());

  const selectedAgent = agentFlag(args);
  const cwdValue = flag(args, "cwd");
  const cwd = cwdValue ? await resolveDirectory(resolve(cwdValue)) : undefined;
  await manager.start({
    ...(cwd ? { cwd } : {}),
    ...(selectedAgent ? { agent: selectedAgent } : {}),
    ...(flag(args, "name") ? { name: flag(args, "name")! } : {}),
  });
  control = new ControlServer(manager, () => void shutdown());
  const info = await control.start();
  process.stdout.write(
    `[baya] Host ${info.pid} online on 127.0.0.1:${info.port}; state ${BAYA_HOME}\n`,
  );
}

async function pair(args: ParsedArgs): Promise<void> {
  await startBackground(args);
  const ttlValue = flag(args, "ttl");
  const ttlSeconds = ttlValue === undefined ? undefined : Number(ttlValue);
  if (
    ttlSeconds !== undefined &&
    (!Number.isFinite(ttlSeconds) || ttlSeconds < 10 || ttlSeconds > 600)
  ) {
    throw new Error("Pairing TTL must be between 10 and 600 seconds.");
  }
  const response = await controlCall<ReturnType<BayaManager["pair"]>>("pair", {
    ...(args.positionals[0] ? { id: args.positionals[0] } : {}),
    ...(ttlSeconds === undefined ? {} : { ttl_ms: Math.floor(ttlSeconds * 1000) }),
  });
  const identity = await getOrCreateEd25519Keypair();
  const relayUrl = resolveRelayUrl().url;
  const uri = buildQRUri({
    token: response.token,
    publicKey: identity.publicKey,
    sessionName: response.session_name,
    roomId: response.room_id,
    relayUrl,
  });
  process.stdout.write(`Relay: ${relayUrl}\n`);
  process.stdout.write(`Session: ${response.session_name} (${response.session_id})\n`);
  process.stdout.write(`Expires: ${new Date(response.expires_at).toLocaleString()}\n`);
  displayQR(uri);
  process.stdout.write(`Pairing URI:\n${uri}\n`);
}

async function devices(args: ParsedArgs): Promise<void> {
  const peers = await listPeers();
  if (jsonFlag(args)) {
    print({ devices: peers }, true);
    return;
  }
  if (peers.length === 0) {
    process.stdout.write("No phones are paired. Run `baya pair`.\n");
    return;
  }
  for (const peer of peers) {
    process.stdout.write(
      `${peer.name}  ${peer.remote_epk.slice(0, 12)}  paired ${new Date(peer.paired_at).toLocaleString()}\n`,
    );
  }
}

async function unpair(args: ParsedArgs): Promise<void> {
  const query = args.positionals[0];
  if (!query) throw new Error("Name or key prefix of the phone is required. See `baya devices`.");
  const removed = await removePeers(query);
  if (removed.length === 0) throw new Error(`No paired phone matches "${query}".`);
  print(
    jsonFlag(args)
      ? { removed }
      : removed.map((peer) => `Unpaired ${peer.name}. It can no longer reach this computer.`),
    jsonFlag(args),
  );
}

async function doctor(args: ParsedArgs): Promise<void> {
  const [agents, peers, running] = await Promise.all([
    availableAgents(),
    listPeers(),
    controlOnline(),
  ]);
  const relay = resolveRelayUrl();
  const result = {
    version: packageVersion(),
    hostname: hostname(),
    node: process.version,
    state_directory: BAYA_HOME,
    relay: { url: relay.url, source: relay.source },
    host: running ? { online: true, pid: running.pid } : { online: false },
    paired_devices: peers.length,
    agents,
  };
  print(result, jsonFlag(args));
}

async function sessions(args: ParsedArgs): Promise<void> {
  const running = await controlOnline();
  if (running) {
    print(running, jsonFlag(args));
    return;
  }
  const records = listSessions().map((session) => ({
    ...session,
    online: false,
    busy: false,
    room_id: roomIdForBayaSession(session),
  }));
  print({ sessions: records }, jsonFlag(args));
}

async function create(args: ParsedArgs): Promise<void> {
  const cwdInput = args.positionals[0];
  const cwd = await resolveDirectory(cwdInput ? resolve(cwdInput) : process.cwd());
  const agent = agentFlag(args) || loadConfig().defaultAgent || "pi";
  const running = await controlOnline();
  if (running) {
    const workspace = await controlCall("open", { cwd, agent });
    print(workspace, jsonFlag(args));
    return;
  }
  const manager = new BayaManager();
  const record = manager.create({
    cwd,
    agent,
    ...(flag(args, "name") ? { name: flag(args, "name")! } : {}),
  });
  print(record, jsonFlag(args));
}

function installService(): void {
  const message = installStartup({
    nodePath: process.execPath,
    entryPath: fileURLToPath(import.meta.url),
    cwd: resolve(process.cwd()),
    path: process.env["PATH"] ?? "",
    logDir: join(BAYA_HOME, "logs"),
  });
  process.stdout.write(`${message}\n`);
}

function uninstallService(): void {
  process.stdout.write(`${uninstallStartup()}\n`);
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  switch (args.command) {
    case "help":
    case "--help":
    case "-h":
      printHelp();
      return;
    case "version":
    case "--version":
    case "-v":
      process.stdout.write(`${packageVersion()}\n`);
      return;
    case "serve":
      await runForeground(args);
      return;
    case "start":
      print(await startBackground(args), jsonFlag(args));
      return;
    case "stop":
      print(await controlCall("stop"), jsonFlag(args));
      return;
    case "status":
      print(await controlCall<StatusResult>("status"), jsonFlag(args));
      return;
    case "sessions":
    case "list":
      await sessions(args);
      return;
    case "new":
    case "open":
      await create(args);
      return;
    case "remove": {
      const id = args.positionals[0];
      if (!id) throw new Error("A session id is required.");
      try {
        print(await controlCall("remove", { id }), jsonFlag(args));
      } catch (error) {
        const record = findSession(id);
        if (!record) throw error;
        const removed = removeSession(record.id);
        print({ removed }, jsonFlag(args));
      }
      return;
    }
    case "pair":
      await pair(args);
      return;
    case "devices":
      await devices(args);
      return;
    case "unpair":
      await unpair(args);
      return;
    case "agents": {
      print(await availableAgents(), jsonFlag(args));
      return;
    }
    case "doctor":
      await doctor(args);
      return;
    case "set-relay": {
      const url = args.positionals[0];
      if (!url) throw new Error("A relay URL is required.");
      saveConfig({ relay: validateRelayUrl(url) });
      process.stdout.write(`Relay saved: ${loadConfig().relay}\nRestart the host to apply it.\n`);
      return;
    }
    case "install-service":
      installService();
      return;
    case "uninstall-service":
      uninstallService();
      return;
    default:
      throw new Error(`Unknown command: ${args.command}\nRun \`baya help\`.`);
  }
}

main().catch((error: unknown) => {
  process.stderr.write(`[baya] ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
