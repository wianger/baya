#!/usr/bin/env node
import { spawn } from "node:child_process";
import {
  createReadStream,
  existsSync,
  mkdirSync,
  openSync,
  statSync,
  watch,
  writeSync,
} from "node:fs";
import { hostname } from "node:os";
import { join, resolve } from "node:path";
import { SessionHub } from "./acp/hub.ts";
import { booleanFlag, type ParsedArgs, parseArgs, stringFlag } from "./cli/args.ts";
import {
  bold,
  cyan,
  dim,
  duration,
  fail,
  green,
  hint,
  ok,
  out,
  red,
  suggest,
  table,
  warn,
  yellow,
} from "./cli/ui.ts";
import {
  AGENT_ID,
  type AgentDefinition,
  BAYA_HOME,
  defaultAgentId,
  ensureBayaHome,
  loadConfig,
  saveConfig,
  splitEnv,
} from "./config.ts";
import { controlCall, readControlInfo } from "./control/client.ts";
import type { HostStatus, SessionStatus } from "./control/protocol.ts";
import { ControlServer } from "./control/server.ts";
import { dshDesktop, isDsh } from "./integrations/dsh_desktop.ts";
import { buildQRUri, displayQR } from "./pairing/qr.ts";
import { getOrCreateEd25519Keypair, listPeers, removePeers } from "./pairing/storage.ts";
import { issuePendingPairToken, type PendingPairToken } from "./pairing/token_store.ts";
import { selfCommand } from "./runtime/self.ts";
import { packageVersion } from "./runtime/version.ts";
import { installStartup, uninstallStartup } from "./service.ts";
import { findSession, folderName, listSessions, removeSession } from "./session/registry.ts";
import {
  directEndpoint,
  hostLabel,
  serveCommand,
  TailnetPairingServer,
  tailnetSelf,
} from "./tailnet/pairing_server.ts";
import { DirectServer } from "./transport/direct_server.ts";
import { findExecutable, resolveDirectory } from "./workspace/directories.ts";

const LABEL_NAMES = { windows: "Windows", wsl: "WSL", linux: "Linux", macos: "macOS" } as const;

type PairInvite = PendingPairToken;

const LOG_FILE = join(BAYA_HOME, "logs", "host.log");

const HELP =
  () => `${bold("baya")} ${dim(packageVersion())} — drive your coding agents from your phone

${bold("Get started")}
  baya                    Start Baya in the background; shows a pairing code if no phone is paired
  baya pair               Show a code to pair another phone

${bold("Sessions")}
  baya status             Host, phones and sessions at a glance
  baya open [folder]      Add a session in a folder  ${dim("--agent <id>")}
  baya close <session>    Remove a session and its history  ${dim("(id prefix or title)")}

${bold("Agents")} ${dim("— any command that speaks ACP (agentclientprotocol.com)")}
  baya agents             List agents
  baya agents add <id> [--name <name>] -- [NAME=value…] <command> [args…]
  baya agents remove <id>
  baya agents default <id>

${bold("Phones")}
  baya devices            List paired phones
  baya unpair <phone>     Revoke a phone  ${dim("(name or key prefix)")}

${bold("Host")}
  baya start | stop | restart
  baya logs [-f]          Show the host log  ${dim("-f follows it")}
  baya doctor             Check Tailscale, identity, agents and pairing
  baya autostart on|off   Start Baya when you log in  ${dim("(no admin rights)")}

${dim("Add --json to status, devices, agents, pair or doctor for machine-readable output.")}
`;

const COMMANDS = [
  "up",
  "serve",
  "start",
  "stop",
  "restart",
  "status",
  "open",
  "close",
  "pair",
  "devices",
  "unpair",
  "logs",
  "doctor",
  "agents",
  "autostart",
  "help",
  "version",
] as const;

// ── helpers ─────────────────────────────────────────────────────────────────

function json(args: ParsedArgs): boolean {
  return booleanFlag(args, "json");
}

function printJson(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function agentFlag(args: ParsedArgs): string | undefined {
  const value = stringFlag(args, "agent");
  if (value === undefined) return undefined;
  if (!loadConfig().agents.some((agent) => agent.id === value)) {
    throw new Error(`No agent named "${value}". See \`baya agents\`.`);
  }
  return value;
}

async function hostStatus(timeoutMs = 1_500): Promise<HostStatus | null> {
  if (!readControlInfo()) return null;
  try {
    return await controlCall<HostStatus>("status", undefined, timeoutMs);
  } catch {
    return null;
  }
}

function sessionRows(sessions: SessionStatus[]): string[] {
  return table(
    sessions.map((session) => [
      session.error
        ? red("✗ failed")
        : session.working
          ? cyan("● working")
          : session.running
            ? green("● ready")
            : dim("○ idle"),
      bold(session.title),
      session.agent,
      dim(session.id.slice(0, 8)),
      dim(session.error ?? session.cwd),
    ]),
  ).map((line) => `  ${line}`);
}

function offlineSessions(): SessionStatus[] {
  return listSessions().map((record) => ({
    id: record.id,
    title: record.title ?? folderName(record.cwd),
    cwd: record.cwd,
    agent: record.agent,
    running: false,
    working: false,
    error: null,
  }));
}

async function printStatus(status: HostStatus): Promise<void> {
  const peers = await listPeers();
  out(
    ok(`Host running ${dim(`pid ${status.pid} · up ${duration(Date.now() - status.started_at)}`)}`),
    status.direct
      ? ok(`Phones reach it at ${dim(status.direct)}`)
      : warn("Phones can't reach this host yet"),
    peers.length > 0
      ? ok(
          `${peers.length} phone${peers.length === 1 ? "" : "s"} paired${dim(
            ` · ${status.phones_connected} connected`,
          )}`,
        )
      : warn("No phone paired"),
  );
  if (!status.direct) out(hint("baya doctor"));
  else if (peers.length === 0) out(hint("baya pair"));
  if (loadConfig().agents.length === 0) {
    out(warn("No agent set up"), hint("baya agents add <id> -- <command that speaks ACP>"));
  }
  out("", bold("Sessions"));
  if (status.sessions.length === 0)
    out(dim("  none — start one from the app, or: baya open <folder>"));
  else out(...sessionRows(status.sessions));
}

// ── host lifecycle ──────────────────────────────────────────────────────────

async function startBackground(): Promise<HostStatus> {
  const current = await hostStatus();
  if (current) return current;

  ensureBayaHome();
  mkdirSync(join(BAYA_HOME, "runtime"), { recursive: true, mode: 0o700 });
  mkdirSync(join(BAYA_HOME, "logs"), { recursive: true, mode: 0o700 });
  const [executable, ...prefix] = selfCommand();
  const serveArgs = [...prefix, "serve", "--log", LOG_FILE];
  if (process.platform === "win32") {
    // Start-Process gives the host a console of its own with its window
    // hidden. Agents and every tool they run share it; a host without a
    // console would make each of those open a visible console window.
    const quote = (value: string): string => `'${value.replace(/'/g, "''")}'`;
    const argumentList = serveArgs.map((arg) => `"${arg}"`).join(" ");
    const script = `Start-Process -WindowStyle Hidden -FilePath ${quote(executable!)} -ArgumentList ${quote(argumentList)}`;
    await new Promise<void>((done, fail) => {
      spawn(
        "powershell.exe",
        [
          "-NoProfile",
          "-NonInteractive",
          "-EncodedCommand",
          Buffer.from(script, "utf16le").toString("base64"),
        ],
        { env: { ...process.env }, stdio: "ignore", windowsHide: true },
      )
        .on("error", fail)
        .on("exit", () => done());
    });
  } else {
    spawn(executable!, serveArgs, {
      detached: true,
      env: { ...process.env },
      stdio: "ignore",
    }).unref();
  }
  for (let attempt = 0; attempt < 75; attempt++) {
    await new Promise((done) => setTimeout(done, 200));
    const status = await hostStatus();
    if (status) return status;
  }
  throw new Error("Baya did not start. See the log: baya logs");
}

async function stopHost(): Promise<boolean> {
  if (!(await hostStatus())) return false;
  await controlCall("stop");
  for (let attempt = 0; attempt < 50; attempt++) {
    await new Promise((done) => setTimeout(done, 100));
    if (!(await hostStatus(500))) return true;
  }
  throw new Error("Baya did not stop in time.");
}

/** `baya`: the one command a new user needs. */
async function up(args: ParsedArgs): Promise<void> {
  const already = await hostStatus();
  const status = already ?? (await startBackground());
  if (json(args)) return printJson(status);
  if (!already) out(ok("Baya started"), "");
  await printStatus(status);
  if (status.direct && (await listPeers()).length === 0) {
    out(
      "",
      bold("Pair your phone"),
      `In the Baya app, choose "Use Tailscale" and type ${bold(status.tailnet ?? "")}, or scan:`,
    );
    await printPairingCode(await controlCall<PairInvite>("pair"));
  }
}

/** Sends the host's output to [path], for a host with no terminal. */
function logTo(path: string): void {
  const fd = openSync(path, "a", 0o600);
  const write = (chunk: string | Uint8Array): boolean => {
    if (typeof chunk === "string") writeSync(fd, chunk);
    else writeSync(fd, chunk);
    return true;
  };
  process.stdout.write = write as typeof process.stdout.write;
  process.stderr.write = write as typeof process.stderr.write;
}

async function runForeground(): Promise<void> {
  if (await hostStatus()) throw new Error("Baya is already running. See `baya status`.");
  const hub = new SessionHub();
  // Every DeepSeek session shows in DeepSeek's desktop app too; sessions
  // already recorded there are left alone.
  const agents = loadConfig().agents;
  for (const session of listSessions()) {
    const definition = agents.find((agent) => agent.id === session.agent);
    if (definition && isDsh(definition) && session.agentSessionId) {
      dshDesktop.register(definition, session.agentSessionId, session.cwd);
    }
  }
  dshDesktop.flush();
  let control: ControlServer | null = null;
  let stopping = false;
  const shutdown = async (): Promise<void> => {
    if (stopping) return;
    stopping = true;
    await control?.close();
    hub.stop();
    process.exit(0);
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());

  await hub.start();
  control = new ControlServer(hub, () => void shutdown());
  // Before the control socket answers, so status knows where phones connect.
  await startTailnet(hub, control);
  const info = await control.start();
  out(`[baya] Host ${info.pid} online; state ${BAYA_HOME}`);
  if (control.direct && process.stdout.isTTY && (await listPeers()).length === 0) {
    out("", "No phone is paired yet. Scan this code with the Baya app:");
    await printPairingCode(issuePendingPairToken());
  }
}

/**
 * Opens this host to phones on the owner's Tailscale account: they connect
 * through `tailscale serve`, and pair by typing this computer's name.
 */
async function startTailnet(hub: SessionHub, control: ControlServer): Promise<void> {
  const self = await tailnetSelf();
  if (!self) {
    out("[baya] Tailscale is not running; phones cannot reach this host. See: baya doctor");
    return;
  }
  const label = hostLabel();
  const identity = await getOrCreateEd25519Keypair();
  const server = new TailnetPairingServer(
    {
      label,
      name: `${hostname()} (${LABEL_NAMES[label]})`,
      key: Buffer.from(identity.publicKey).toString("base64"),
    },
    () => pairingUri(issuePendingPairToken()),
    new DirectServer(hub),
  );
  try {
    await server.start(self);
  } catch (error) {
    out(`[baya] Tailscale endpoint unavailable: ${error instanceof Error ? error.message : error}`);
    return;
  }
  control.tailnetName = self.name;
  control.direct = await directEndpoint(self, label);
  out(
    control.direct
      ? `[baya] Phones reach this host at ${control.direct}; to pair, they type "${self.name}"`
      : `[baya] Phones need one route to reach this host: ${serveCommand(label)}`,
  );
  // Picks up a serve route added while running.
  setInterval(async () => {
    control.direct = await directEndpoint(self, label);
  }, 30_000).unref();
}

// ── sessions ────────────────────────────────────────────────────────────────

async function status(args: ParsedArgs): Promise<void> {
  const current = await hostStatus();
  if (json(args)) return printJson(current ?? { running: false, sessions: offlineSessions() });
  if (current) return printStatus(current);
  out(warn("Baya is not running"), hint("baya"));
  const sessions = offlineSessions();
  if (sessions.length > 0) out("", bold("Sessions"), ...sessionRows(sessions));
}

async function open(args: ParsedArgs): Promise<void> {
  const cwd = await resolveDirectory(resolve(args.positionals[0] ?? process.cwd()));
  const agent = agentFlag(args) ?? defaultAgentId();
  if (!agent) throw new Error("No agent is set up. Add one: baya agents add <id> -- <command>");
  await startBackground();
  const opened = await controlCall<SessionStatus>("open", { cwd, agent });
  if (json(args)) return printJson(opened);
  out(
    ok(`Added ${bold(opened.title)} ${dim(`${agent} · ${cwd}`)}`),
    dim("  It shows up in the app now."),
  );
}

async function close(args: ParsedArgs): Promise<void> {
  const query = args.positionals[0];
  if (!query) throw new Error("Which session? Pass its id prefix or title (see `baya status`).");
  const record = findSession(query);
  if (!record) throw new Error(`No session matches "${query}". See \`baya status\`.`);
  if (await hostStatus()) await controlCall("remove", { id: record.id });
  else removeSession(record.id);
  out(ok(`Closed ${bold(record.title ?? folderName(record.cwd))}`));
}

// ── phones ──────────────────────────────────────────────────────────────────

async function pair(args: ParsedArgs): Promise<void> {
  await startBackground();
  const ttlValue = stringFlag(args, "ttl");
  const ttlSeconds = ttlValue === undefined ? undefined : Number(ttlValue);
  if (
    ttlSeconds !== undefined &&
    (!Number.isFinite(ttlSeconds) || ttlSeconds < 10 || ttlSeconds > 600)
  ) {
    throw new Error("--ttl must be between 10 and 600 seconds.");
  }
  const invite = await controlCall<PairInvite>(
    "pair",
    ttlSeconds === undefined ? {} : { ttl_ms: Math.floor(ttlSeconds * 1000) },
  );
  if (json(args)) return printJson({ ...invite, uri: await pairingUri(invite) });
  out("Open the Baya app and scan this code:");
  await printPairingCode(invite);
}

/** A pairing code naming where the phone reaches this host. */
async function pairingUri(invite: PairInvite): Promise<string> {
  const identity = await getOrCreateEd25519Keypair();
  const self = await tailnetSelf();
  const endpoint = self ? await directEndpoint(self) : null;
  if (!endpoint) throw new Error("Phones can't reach this host yet. Run `baya doctor`.");
  const name = `${hostname()} (${LABEL_NAMES[hostLabel()]})`;
  return buildQRUri({ token: invite.token, publicKey: identity.publicKey, name, endpoint });
}

async function printPairingCode(invite: PairInvite): Promise<void> {
  const uri = await pairingUri(invite);
  displayQR(uri);
  const minutes = Math.max(1, Math.round((invite.expires_at - Date.now()) / 60_000));
  out(dim(`Valid for ${minutes} min, once. Can't scan? Paste this in the app:`), dim(uri));
}

async function devices(args: ParsedArgs): Promise<void> {
  const peers = await listPeers();
  if (json(args)) return printJson({ devices: peers });
  if (peers.length === 0) return out(warn("No phone paired"), hint("baya pair"));
  out(
    ...table(
      peers.map((peer) => [
        bold(peer.name),
        dim(peer.remote_epk.slice(0, 10)),
        dim(`paired ${new Date(peer.paired_at).toLocaleDateString()}`),
      ]),
    ),
  );
}

async function unpair(args: ParsedArgs): Promise<void> {
  const query = args.positionals[0];
  if (!query) throw new Error("Which phone? Pass its name or key prefix (see `baya devices`).");
  const removed = (await hostStatus())
    ? (await controlCall<{ removed: Awaited<ReturnType<typeof removePeers>> }>("unpair", { query }))
        .removed
    : await removePeers(query);
  if (removed.length === 0) throw new Error(`No paired phone matches "${query}".`);
  if (json(args)) return printJson({ removed });
  for (const peer of removed) {
    out(ok(`Unpaired ${bold(peer.name)}; it can no longer reach this computer.`));
  }
}

// ── host tools ──────────────────────────────────────────────────────────────

async function logs(args: ParsedArgs): Promise<void> {
  if (!existsSync(LOG_FILE)) return out(dim("No log yet. The background host writes it."));
  const follow = booleanFlag(args, "follow") || args.positionals.includes("-f");
  const size = statSync(LOG_FILE).size;
  await new Promise<void>((done) =>
    createReadStream(LOG_FILE, { start: Math.max(0, size - 16 * 1024) })
      .on("end", done)
      .pipe(process.stdout, { end: false }),
  );
  if (!follow) return;
  let position = size;
  watch(LOG_FILE, () => {
    const next = statSync(LOG_FILE).size;
    if (next < position) position = 0;
    if (next === position) return;
    createReadStream(LOG_FILE, { start: position, end: next - 1 }).pipe(process.stdout, {
      end: false,
    });
    position = next;
  });
  await new Promise(() => {});
}

async function doctor(args: ParsedArgs): Promise<void> {
  const [agentList, peers, host, self, identityError] = await Promise.all([
    agentStatuses(),
    listPeers(),
    hostStatus(),
    tailnetSelf(),
    getOrCreateEd25519Keypair().then(
      () => null,
      (error: unknown) => (error instanceof Error ? error.message : String(error)),
    ),
  ]);
  const direct = self ? await directEndpoint(self) : null;
  if (json(args)) {
    return printJson({
      version: packageVersion(),
      hostname: hostname(),
      node: process.version,
      state_directory: BAYA_HOME,
      tailscale: self ? { name: self.name, direct } : null,
      identity: identityError ? { ok: false, error: identityError } : { ok: true },
      host: host ? { online: true, pid: host.pid } : { online: false },
      paired_devices: peers.length,
      agents: agentList,
    });
  }
  const lines = [
    dim(`Baya ${packageVersion()} · Node ${process.version} · ${hostname()} · ${BAYA_HOME}`),
    "",
    identityError ? fail(`Identity unreadable: ${identityError}`) : ok("Identity ready"),
  ];
  lines.push(host ? ok(`Host running ${dim(`pid ${host.pid}`)}`) : warn("Host not running"));
  if (!host) lines.push(hint("baya"));
  if (direct) {
    lines.push(ok(`Phones reach it at ${dim(direct)}`));
  } else if (self) {
    const where = hostLabel() === "wsl" ? "on Windows" : "on this computer";
    lines.push(
      fail("Tailscale is on, but does not route to this host"),
      hint(`${where}, once: ${serveCommand()}`),
    );
  } else {
    lines.push(
      fail("Tailscale is not running"),
      hint("phones reach Baya over Tailscale: https://tailscale.com/download"),
    );
  }
  lines.push(peers.length ? ok(`${peers.length} phone(s) paired`) : warn("No phone paired"));
  if (!peers.length) lines.push(hint("baya pair"));
  for (const agent of agentList) {
    lines.push(
      agent.available
        ? ok(`${agent.name} ${dim(agent.command.join(" "))}`)
        : warn(`${agent.name}: ${bold(agent.command[0]!)} is not on PATH`),
    );
  }
  if (agentList.length === 0) {
    lines.push(fail("No agent set up"), hint("baya agents add <id> -- <command that speaks ACP>"));
  }
  out(...lines);
}

async function agentStatuses(): Promise<
  Array<AgentDefinition & { available: boolean; default: boolean }>
> {
  const config = loadConfig();
  const fallback = defaultAgentId(config);
  return Promise.all(
    config.agents.map(async (agent) => ({
      ...agent,
      available: (await findExecutable(agent.command[0]!)) !== null,
      default: agent.id === fallback,
    })),
  );
}

async function agents(args: ParsedArgs): Promise<void> {
  const [action, id] = args.positionals;
  const config = loadConfig();
  switch (action) {
    case undefined: {
      const list = await agentStatuses();
      if (json(args)) return printJson(list);
      if (list.length === 0) {
        return out(
          warn("No agent set up"),
          hint("baya agents add <id> [--name <name>] -- <command that speaks ACP>"),
        );
      }
      return out(
        ...table(
          list.map((agent) => [
            agent.available ? green("✓") : yellow("–"),
            bold(agent.id),
            agent.name,
            dim(
              [
                ...Object.entries(agent.env ?? {}).map(([key, value]) => `${key}=${value}`),
                ...agent.command,
              ].join(" "),
            ),
            agent.default ? cyan("default") : "",
          ]),
        ),
      );
    }
    case "add": {
      if (!id || !AGENT_ID.test(id)) {
        throw new Error("Give the agent a short id: lowercase letters, digits, - or _.");
      }
      const { env, command } = splitEnv(args.passthrough);
      if (command.length === 0) {
        throw new Error(`Put the command after --, e.g. baya agents add ${id} -- my-agent --acp`);
      }
      const name = stringFlag(args, "name") ?? id;
      const entry = { id, name, command, ...(Object.keys(env).length > 0 ? { env } : {}) };
      const others = config.agents.filter((agent) => agent.id !== id);
      saveConfig({ ...config, agents: [...others, entry] });
      out(ok(`${others.length < config.agents.length ? "Updated" : "Added"} ${bold(name)}`));
      if (!(await findExecutable(command[0]!))) out(warn(`${command[0]} is not on PATH yet`));
      return;
    }
    case "remove": {
      if (!id || !config.agents.some((agent) => agent.id === id)) {
        throw new Error(`No agent named "${id ?? ""}". See \`baya agents\`.`);
      }
      const { defaultAgent, ...rest } = config;
      saveConfig({
        ...rest,
        agents: config.agents.filter((agent) => agent.id !== id),
        ...(defaultAgent && defaultAgent !== id ? { defaultAgent } : {}),
      });
      return out(ok(`Removed ${bold(id)}; its sessions stay until you close them.`));
    }
    case "default": {
      if (!id || !config.agents.some((agent) => agent.id === id)) {
        throw new Error(`No agent named "${id ?? ""}". See \`baya agents\`.`);
      }
      saveConfig({ ...config, defaultAgent: id });
      return out(ok(`New sessions use ${bold(id)} unless you pick another.`));
    }
    default:
      throw new Error("Use `baya agents`, `baya agents add`, `remove` or `default`.");
  }
}

function autostart(args: ParsedArgs): void {
  const mode = args.positionals[0];
  if (mode === "on") {
    out(
      ok(
        installStartup({
          command: selfCommand(),
          cwd: resolve(process.cwd()),
          path: process.env["PATH"] ?? "",
          logDir: join(BAYA_HOME, "logs"),
        }),
      ),
    );
  } else if (mode === "off") {
    out(ok(uninstallStartup()));
  } else {
    throw new Error("Use `baya autostart on` or `baya autostart off`.");
  }
}

// ── entry ───────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  switch (args.command) {
    case "up":
      return up(args);
    case "serve": {
      const log = stringFlag(args, "log");
      if (log) logTo(log);
      return runForeground();
    }
    case "start": {
      const current = await startBackground();
      return json(args) ? printJson(current) : printStatus(current);
    }
    case "stop":
      return out((await stopHost()) ? ok("Baya stopped") : dim("Baya was not running"));
    case "restart":
      await stopHost();
      return printStatus(await startBackground());
    case "status":
      return status(args);
    case "open":
      return open(args);
    case "close":
      return close(args);
    case "pair":
      return pair(args);
    case "devices":
      return devices(args);
    case "unpair":
      return unpair(args);
    case "logs":
      return logs(args);
    case "doctor":
      return doctor(args);
    case "agents":
      return agents(args);
    case "autostart":
      return autostart(args);
    case "help":
      return void process.stdout.write(HELP());
    case "version":
      return out(packageVersion());
    default: {
      const guess = suggest(args.command, COMMANDS);
      throw new Error(
        `Unknown command "${args.command}".${guess ? ` Did you mean \`baya ${guess}\`?` : ""} Run \`baya help\`.`,
      );
    }
  }
}

// `baya status | head` closes the pipe early; that is not an error.
process.stdout.on("error", (error: NodeJS.ErrnoException) => {
  if (error.code === "EPIPE") process.exit(0);
  throw error;
});

main().catch((error: unknown) => {
  process.stderr.write(`${red("✗")} ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
