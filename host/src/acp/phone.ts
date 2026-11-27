import { randomUUID } from "node:crypto";
import { hostname } from "node:os";
import { loadConfig } from "../config.ts";
import { PaneSession } from "../herdr/pane_session.ts";
import { PhoneTerminals, resumeCommand } from "../herdr/phone_terminals.ts";
import { adbConnect, adbDisconnect, adbPair, adbStatus } from "../integrations/adb.ts";
import { logOnce } from "../log_once.ts";
import { pairPhone } from "../pairing/service.ts";
import { packageVersion } from "../runtime/version.ts";
import { sunshinePin, sunshineState } from "../screen/sunshine.ts";
import { tailnetSelf } from "../tailnet/pairing_server.ts";
import type { DataFrame } from "../transport/noise.ts";
import { browseDirectory, resolveDirectory } from "../workspace/directories.ts";
import { convertToPdf, extractEntry, listArchive } from "../workspace/file_views.ts";
import {
  createWorktree,
  gitCommit,
  gitDiff,
  gitPush,
  gitRevertFile,
  gitRevertHunk,
  gitStatus,
  openPullRequest,
  removeWorktree,
} from "../workspace/git.ts";
import { browseSessionFiles, readSessionFile } from "../workspace/session_files.ts";
import { openDownload, uploads } from "../workspace/transfer.ts";
import type { Cursor } from "./hosted_session.ts";
import type { Conversation, HubPhone, SessionHub } from "./hub.ts";
import { isObject, type Json, JsonRpcPeer, RpcError, type RpcId } from "./jsonrpc.ts";
import { BAYA_META, PROTOCOL_VERSION } from "./schema.ts";

const NOT_PAIRED = -32000;

/**
 * One phone connection. To the phone, this computer is a single ACP agent
 * whose sessions run on whichever agent each was created with; Baya's own
 * features are `_baya/*` methods.
 */
export class PhoneConnection implements HubPhone {
  readonly key: string;
  private readonly hub: SessionHub;
  private readonly peer: JsonRpcPeer;
  private readonly closeSocket: (code: number, reason: string) => void;
  private initialized = false;
  private readonly sendData: (
    stream: number,
    offset: number,
    bytes: Buffer,
    buffer?: number,
  ) => Promise<void>;
  /** Downloads under way, by the phone's stream id. */
  private readonly downloads = new Set<number>();
  /** Owns this connection's half-sent uploads. */
  private readonly id = randomUUID();
  /** herdr-core's terminals, as this phone watches them. */
  private readonly terminals: PhoneTerminals;

  constructor(options: {
    key: string;
    hub: SessionHub;
    send: (message: Json) => void;
    close: (code: number, reason: string) => void;
    /** [buffer]: bytes the socket may hold before this waits. */
    sendData?: (stream: number, offset: number, bytes: Buffer, buffer?: number) => Promise<void>;
  }) {
    this.sendData =
      options.sendData ??
      (() => Promise.reject(new Error("This connection carries no file data.")));
    this.key = options.key;
    this.hub = options.hub;
    this.closeSocket = options.close;
    this.peer = new JsonRpcPeer({
      write: options.send,
      onRequest: (method, params) => this.handle(method, params),
      onNotification: (method, params) => this.handleNotification(method, params),
    });
    this.terminals = new PhoneTerminals({
      notify: (method, params) => this.notify(method, params as Json),
      sendData: (stream, offset, bytes, buffer) => this.sendData(stream, offset, bytes, buffer),
    });
    this.hub.connect(this);
  }

  get ready(): boolean {
    return this.initialized;
  }

  receive(message: unknown): void {
    this.peer.receive(message);
  }

  notify(method: string, params: Json): void {
    this.peer.notify(method, params);
  }

  ask(method: string, params: Json): { id: RpcId; result: Promise<unknown> } {
    const result = this.peer.request(method, params);
    return { id: this.peer.lastRequestId, result };
  }

  close(code: number, reason: string): void {
    this.closeSocket(code, reason);
  }

  /** File bytes for an upload. */
  receiveData(frame: DataFrame): void {
    if (!this.hub.isPaired(this.key)) return;
    uploads.data(this.id, frame.stream, frame.offset, frame.bytes, (uploadId, received, error) =>
      this.notify("_baya/upload_progress", { uploadId, received, ...(error ? { error } : {}) }),
    );
  }

  /** Streams a download, then says how it ended. */
  private async pump(stream: number, download: Awaited<ReturnType<typeof openDownload>>) {
    this.downloads.add(stream);
    let sent = 0;
    let error: string | undefined;
    try {
      sent = await download.pump(
        (offset, bytes) => this.sendData(stream, offset, bytes),
        () => !this.downloads.has(stream),
      );
    } catch (failure) {
      error = failure instanceof Error ? failure.message : String(failure);
    }
    if (!this.downloads.delete(stream)) return;
    this.notify("_baya/stream_end", {
      stream,
      size: download.size,
      sent,
      ...(error ? { error } : {}),
    });
  }

  /** The socket closed. */
  closed(): void {
    this.peer.close(new Error("The phone disconnected."));
    this.hub.disconnect(this);
    this.downloads.clear();
    uploads.detach(this.id);
    this.terminals.close();
  }

  private async handle(method: string, params: Json): Promise<unknown> {
    if (method === "_baya/pair") {
      const result = await pairPhone(this.key, params["token"], params["deviceName"]);
      await this.hub.refreshPeers();
      return result;
    }
    if (!this.hub.isPaired(this.key)) {
      logOnce(
        `unpaired:${this.key}`,
        `A phone that is not paired here tried to connect (key ${this.key.slice(0, 8)}…); pair it with: baya pair`,
      );
      throw new RpcError(NOT_PAIRED, "This phone is not paired with this computer.", {
        reason: "unpaired",
      });
    }
    switch (method) {
      case "initialize": {
        this.initialized = true;
        const device = bayaMeta(params)["device"];
        this.hub.seen(this.key, typeof device === "string" ? device : undefined);
        return this.initialize();
      }
      case "session/list":
        return {
          sessions: this.hub
            .list(typeof params["cwd"] === "string" ? params["cwd"] : undefined)
            .map((session) => session.info()),
        };
      case "session/new": {
        const cwd = await resolveDirectory(stringParam(params, "cwd"));
        const meta = bayaMeta(params);
        const agent = typeof meta["agent"] === "string" ? meta["agent"] : undefined;
        // Adopting one of the agent's own conversations replays it.
        const adopted =
          typeof meta["agentSessionId"] === "string" ? meta["agentSessionId"] : undefined;
        // Its title comes along, as the agent named it.
        const title = typeof meta["title"] === "string" ? meta["title"].trim() : "";
        // A new conversation runs in a herdr pane where it can: the agent's
        // own TUI, visible on the computer, the chat read from its record.
        const inPane = adopted ? null : await this.hub.startInPane(cwd, agent);
        if (inPane) {
          const setup = await inPane.attach(this, false);
          return { sessionId: inPane.id, ...setup };
        }
        const session = this.hub.create(
          cwd,
          agent,
          adopted
            ? {
                agentSessionId: adopted,
                ...(title ? { title, titleSource: "agent" as const } : {}),
              }
            : {},
        );
        const setup = await session.attach(this, Boolean(adopted));
        return { sessionId: session.id, ...setup };
      }
      case "session/load": {
        // A conversation Baya ran itself moves into herdr when opened: one
        // process, in a pane on the computer, the chat read from its record.
        const id = stringParam(params, "sessionId");
        const moved = await this.hub.moveToPane(id).catch(() => null);
        if (moved) return moved.attach(this, true);
        return this.session(params).attach(this, true, cursorParam(bayaMeta(params)["resume"]));
      }
      case "session/resume":
        return this.session(params).attach(this, false);
      case "session/prompt":
        return this.session(params).prompt(this, params);
      case "session/set_config_option":
        return this.session(params).setConfigOption(this, params);
      case "session/set_mode":
        return this.session(params).setMode(this, params);
      case "session/close":
        this.session(params).detach(this);
        return {};
      case "_baya/fork": {
        // A new session holding [sessionId]'s conversation up to the agent
        // message [messageId], or none of it without one.
        const source = this.hub.hosted(stringParam(params, "sessionId"));
        if (!source) {
          throw RpcError.invalidParams("This agent runs in herdr: branch it in its terminal.");
        }
        const messageId = optionalString(params, "messageId");
        const fingerprint = optionalString(params, "messageFingerprint");
        const occurrence = params["messageOccurrence"];
        const agentSessionId = messageId
          ? await this.hub.fork(source, {
              messageId,
              ...(fingerprint ? { messageFingerprint: fingerprint } : {}),
              ...(typeof occurrence === "number" ? { messageOccurrence: occurrence } : {}),
            })
          : undefined;
        const session = this.hub.create(source.record.cwd, source.record.agent, {
          title: source.title,
          titleSource: source.record.titleSource ?? "prompt",
          ...(agentSessionId ? { agentSessionId } : {}),
        });
        return { session: session.info() };
      }
      case "_baya/rename":
        this.session(params).rename(stringParam(params, "title"));
        return { session: this.session(params).info() };
      case "session/delete":
        this.hub.delete(this.session(params).id);
        return {};
      case "_baya/browse":
        return browseDirectory(optionalString(params, "path"), params["showHidden"] === true);
      case "_baya/files":
        return browseSessionFiles(
          this.session(params).record.cwd,
          optionalString(params, "path"),
          params["showHidden"] === true,
        );
      case "_baya/agent_auth":
        return this.hub.agentAuth(params["agent"]);
      case "_baya/authenticate":
        return this.hub.authenticate(params["agent"], params["methodId"]);
      case "_baya/logout":
        return this.hub.logout(params["agent"]);
      case "_baya/agent_sessions":
        return this.hub.agentSessions(
          params["agent"],
          await resolveDirectory(stringParam(params, "cwd")),
        );
      case "_baya/computer_sessions":
        return this.hub.computerSessions();
      case "_baya/read_file":
        return readSessionFile(this.session(params).record.cwd, stringParam(params, "path"));
      case "_baya/upload_begin": {
        const begun = await uploads.begin(this.key, this.session(params).record.cwd, {
          name: stringParam(params, "name"),
          size: numberParam(params, "size"),
          dir: optionalString(params, "dir"),
        });
        await uploads.attach(this.key, begun.uploadId, this.id, numberParam(params, "stream"));
        return begun;
      }
      case "_baya/upload_resume":
        return uploads.attach(
          this.key,
          stringParam(params, "uploadId"),
          this.id,
          numberParam(params, "stream"),
        );
      case "_baya/upload_finish":
        return uploads.finish(this.key, stringParam(params, "uploadId"));
      case "_baya/upload_cancel":
        await uploads.cancel(this.key, stringParam(params, "uploadId"));
        return {};
      case "_baya/download_open": {
        const stream = numberParam(params, "stream");
        const download = await openDownload(
          this.session(params).record.cwd,
          stringParam(params, "path"),
          optionalNumber(params, "offset") ?? 0,
        );
        // After the reply: the phone listens for the stream before asking.
        setImmediate(() => void this.pump(stream, download));
        return { name: download.name, size: download.size };
      }
      case "_baya/stream_close":
        this.downloads.delete(numberParam(params, "stream"));
        return {};
      case "_baya/archive_list":
        return listArchive(this.session(params).record.cwd, stringParam(params, "path"));
      case "_baya/archive_extract":
        return extractEntry(
          this.session(params).record.cwd,
          stringParam(params, "path"),
          stringParam(params, "entry"),
        );
      case "_baya/convert_pdf":
        return convertToPdf(this.session(params).record.cwd, stringParam(params, "path"));
      case "_baya/adb_status":
        return adbStatus();
      case "_baya/adb_pair":
        return adbPair(params["address"], params["code"]);
      case "_baya/adb_connect":
        return adbConnect(params["address"]);
      case "_baya/adb_disconnect":
        return adbDisconnect(params["address"]);
      case "_baya/git_status":
        return gitStatus(this.session(params).record.cwd);
      case "_baya/git_diff":
        return gitDiff(this.session(params).record.cwd, stringParam(params, "path"));
      case "_baya/git_revert": {
        const cwd = this.session(params).record.cwd;
        const path = stringParam(params, "path");
        const hunk = params["hunk"];
        return typeof hunk === "number" ? gitRevertHunk(cwd, path, hunk) : gitRevertFile(cwd, path);
      }
      case "_baya/git_commit":
        return gitCommit(this.session(params).record.cwd, stringParam(params, "message"));
      case "_baya/git_push":
        return gitPush(this.session(params).record.cwd);
      case "_baya/pr_create":
        return openPullRequest(
          this.session(params).record.cwd,
          stringParam(params, "title"),
          optionalString(params, "body") ?? "",
        );
      case "_baya/worktree_create":
        return createWorktree(
          await resolveDirectory(stringParam(params, "cwd")),
          stringParam(params, "name"),
        );
      case "_baya/terminal_list":
        return this.terminals.list();
      case "_baya/terminal_run": {
        const cwd = optionalString(params, "cwd");
        return this.terminals.run({
          ...params,
          ...(cwd ? { cwd: await resolveDirectory(cwd) } : {}),
        });
      }
      case "_baya/pane_screen":
        return this.pane(params).screen();
      case "_baya/pane_input": {
        const keys = Array.isArray(params["keys"])
          ? params["keys"].filter((key): key is string => typeof key === "string")
          : [];
        await this.pane(params).input(optionalString(params, "text"), keys);
        return {};
      }
      case "_baya/terminal_session": {
        // Its terminal is its pane: a herdr-core terminal streams to the
        // phone (colours, live); a pane of herdr's own shows its screen.
        const live = this.hub.get(stringParam(params, "sessionId"));
        if (live instanceof PaneSession) {
          const terminal = await live.terminal().catch(() => null);
          return terminal ? { available: true, terminal } : { available: true, pane: true };
        }
        const { record } = this.session(params);
        const agent = loadConfig().agents.find((a) => a.id === record.agent);
        return this.terminals.forSession({
          session: record.id,
          cwd: record.cwd,
          agent: record.agent,
          resume: resumeCommand(record.agent, record.agentSessionId, agent?.env, record.cwd),
        });
      }
      case "_baya/terminal_attach":
        return this.terminals.attach(params);
      case "_baya/terminal_detach":
        this.terminals.detach(numberParam(params, "stream"));
        return {};
      case "_baya/terminal_read":
        return this.terminals.read(stringParam(params, "terminal"), params["lines"]);
      case "_baya/terminal_kill":
        return this.terminals.kill(stringParam(params, "terminal"));
      case "_baya/terminal_remove":
        return this.terminals.remove(stringParam(params, "terminal"));
      case "_baya/screen_info": {
        // Where the phone's Moonlight core reaches Sunshine: this computer's
        // tailnet name, and whether Sunshine is ready to stream.
        const [state, self] = await Promise.all([sunshineState(), tailnetSelf()]);
        return { ...state, address: self?.dnsName ?? null };
      }
      case "_baya/screen_pair":
        await sunshinePin(stringParam(params, "pin"), optionalString(params, "name") ?? "Baya");
        return {};
      case "_baya/worktree_remove":
        return removeWorktree(stringParam(params, "path"));
      default:
        throw RpcError.methodNotFound(method);
    }
  }

  private handleNotification(method: string, params: Json): void {
    if (!this.hub.isPaired(this.key)) return;
    // Keys and sizes: nothing waits on a reply.
    if (method === "_baya/terminal_input") {
      this.terminals.input(params["stream"], params["data"]);
      return;
    }
    if (method === "_baya/terminal_resize") {
      this.terminals.resize(params["stream"], params["cols"], params["rows"]);
      return;
    }
    if (method === "session/cancel") {
      const id = params["sessionId"];
      if (typeof id === "string") this.hub.get(id)?.cancel();
    }
  }

  private async initialize(): Promise<Json> {
    return {
      protocolVersion: PROTOCOL_VERSION,
      agentInfo: { name: "baya", title: "Baya", version: packageVersion() },
      agentCapabilities: {
        loadSession: true,
        // Each session answers for its own agent in `_meta.baya.promptCapabilities`.
        promptCapabilities: { image: true, audio: false, embeddedContext: false },
        sessionCapabilities: { list: {}, resume: {}, close: {}, delete: {} },
      },
      authMethods: [],
      _meta: {
        [BAYA_META]: {
          hostname: hostname(),
          // Whether this computer's screen can be controlled from the phone.
          screen: (await sunshineState()).ready,
          agents: (await this.hub.agents()).map(({ id, name, available }) => ({
            id,
            name,
            available,
          })),
        },
      },
    };
  }

  private pane(params: Json): PaneSession {
    const session = this.session(params);
    if (!(session instanceof PaneSession)) {
      throw RpcError.invalidParams("This session doesn't run in a herdr pane.");
    }
    return session;
  }

  private session(params: Json): Conversation {
    const id = stringParam(params, "sessionId");
    const session = this.hub.get(id);
    if (!session) throw RpcError.notFound("This session no longer exists on the computer.");
    return session;
  }
}

function stringParam(params: Json, name: string): string {
  const value = params[name];
  if (typeof value !== "string" || !value) throw RpcError.invalidParams(`${name} is required.`);
  return value;
}

function numberParam(params: Json, name: string): number {
  const value = params[name];
  if (typeof value !== "number") throw RpcError.invalidParams(`${name} is required.`);
  return value;
}

function optionalNumber(params: Json, name: string): number | undefined {
  const value = params[name];
  return typeof value === "number" ? value : undefined;
}

function optionalString(params: Json, name: string): string | undefined {
  const value = params[name];
  return typeof value === "string" && value ? value : undefined;
}

function bayaMeta(params: Json): Json {
  const meta = params["_meta"];
  const baya = isObject(meta) ? meta[BAYA_META] : undefined;
  return isObject(baya) ? baya : {};
}

/** A `{epoch, seq}` resume cursor, or undefined. */
function cursorParam(value: unknown): Cursor | undefined {
  if (!isObject(value)) return undefined;
  const { epoch, seq } = value;
  return typeof epoch === "string" && typeof seq === "number" && Number.isInteger(seq)
    ? { epoch, seq }
    : undefined;
}
