import { randomUUID } from "node:crypto";
import { hostname } from "node:os";
import { adbConnect, adbDisconnect, adbPair, adbStatus } from "../integrations/adb.ts";
import { pairPhone } from "../pairing/service.ts";
import { PREVIEW_TOKEN_HEADER, previewPorts, previews } from "../preview/preview.ts";
import { packageVersion } from "../runtime/version.ts";
import { hostLabel, servePath, tailnetPairPort } from "../tailnet/pairing_server.ts";
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
import type { HostedSession } from "./hosted_session.ts";
import type { HubPhone, SessionHub } from "./hub.ts";
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
  private readonly sendData: (stream: number, offset: number, bytes: Buffer) => Promise<void>;
  /** Downloads under way, by the phone's stream id. */
  private readonly downloads = new Set<number>();
  /** Owns this connection's half-sent uploads. */
  private readonly id = randomUUID();

  constructor(options: {
    key: string;
    hub: SessionHub;
    send: (message: Json) => void;
    close: (code: number, reason: string) => void;
    sendData?: (stream: number, offset: number, bytes: Buffer) => Promise<void>;
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
  }

  private async handle(method: string, params: Json): Promise<unknown> {
    if (method === "_baya/pair") {
      const result = await pairPhone(this.key, params["token"], params["deviceName"]);
      await this.hub.refreshPeers();
      return result;
    }
    if (!this.hub.isPaired(this.key)) {
      throw new RpcError(NOT_PAIRED, "This phone is not paired with this computer.", {
        reason: "unpaired",
      });
    }
    switch (method) {
      case "initialize":
        this.initialized = true;
        return this.initialize();
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
        const session = this.hub.create(cwd, agent, adopted ? { agentSessionId: adopted } : {});
        const setup = await session.attach(this, Boolean(adopted));
        return { sessionId: session.id, ...setup };
      }
      case "session/load":
        return this.session(params).attach(this, true);
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
        const source = this.session(params);
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
      case "_baya/preview_ports":
        return {
          ports: await previewPorts([tailnetPairPort(hostLabel())]),
          path: `${servePath(hostLabel())}/preview`,
        };
      case "_baya/preview_open": {
        const port = params["port"];
        if (typeof port !== "number") throw RpcError.invalidParams("A preview needs a port.");
        return {
          token: previews.open(port),
          header: PREVIEW_TOKEN_HEADER,
          path: `${servePath(hostLabel())}/preview`,
        };
      }
      case "_baya/preview_close": {
        const port = params["port"];
        if (typeof port === "number") previews.close(port);
        return {};
      }
      case "_baya/worktree_create":
        return createWorktree(
          await resolveDirectory(stringParam(params, "cwd")),
          stringParam(params, "name"),
        );
      case "_baya/worktree_remove":
        return removeWorktree(stringParam(params, "path"));
      default:
        throw RpcError.methodNotFound(method);
    }
  }

  private handleNotification(method: string, params: Json): void {
    if (!this.hub.isPaired(this.key)) return;
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
          agents: (await this.hub.agents()).map(({ id, name, available }) => ({
            id,
            name,
            available,
          })),
        },
      },
    };
  }

  private session(params: Json): HostedSession {
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
