import { hostname } from "node:os";
import { pairPhone } from "../pairing/service.ts";
import { packageVersion } from "../runtime/version.ts";
import { browseDirectory, resolveDirectory } from "../workspace/directories.ts";
import { browseSessionFiles, readSessionFile } from "../workspace/session_files.ts";
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

  constructor(options: {
    key: string;
    hub: SessionHub;
    send: (message: Json) => void;
    close: (code: number, reason: string) => void;
  }) {
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

  /** The socket closed. */
  closed(): void {
    this.peer.close(new Error("The phone disconnected."));
    this.hub.disconnect(this);
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

function optionalString(params: Json, name: string): string | undefined {
  const value = params[name];
  return typeof value === "string" && value ? value : undefined;
}

function bayaMeta(params: Json): Json {
  const meta = params["_meta"];
  const baya = isObject(meta) ? meta[BAYA_META] : undefined;
  return isObject(baya) ? baya : {};
}
