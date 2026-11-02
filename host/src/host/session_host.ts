import type { AgentAdapter } from "../adapters/types.ts";
import { PairingService } from "../pairing/service.ts";
import type { ClientMessage, ServerMessage } from "../protocol/types.ts";
import { roomIdFor, sessionKeyForId } from "../rooms.ts";
import { packageVersion } from "../runtime/version.ts";
import { type BayaSessionRecord, listSessions } from "../session/registry.ts";
import { OwnerRelayHost } from "../transport/owner_host.ts";
import type { PeerChannel } from "../transport/peer_channel.ts";
import { handleWorkspaceRequest, type OpenWorkspace } from "../workspace/service.ts";

export function roomIdForBayaSession(
  session: Pick<BayaSessionRecord, "id" | "cwd" | "agent">,
): string {
  return roomIdFor(session.cwd, `${session.agent}:${session.id}`);
}

/**
 * Session inventory is a property of the resident Baya host, not of whichever
 * agent happens to run in the current room. Keeping it here prevents agent
 * adapters from drifting and accidentally surfacing a transport-level
 * inventory request as a chat error.
 */
export function sessionInventoryResponse(
  inReplyTo: string,
  sessions: ReadonlyArray<Pick<BayaSessionRecord, "id">> = listSessions(),
  scannedAt = Date.now(),
): Extract<ServerMessage, { type: "sessions_inventory" }> {
  return {
    type: "sessions_inventory",
    in_reply_to: inReplyTo,
    session_keys: sessions.map((session) => sessionKeyForId(session.id)),
    scanned_at: scannedAt,
    complete: true,
  };
}

export class ManagedSessionHost {
  readonly roomId: string;
  readonly startedAt = Date.now();
  private readonly relay: OwnerRelayHost;
  private readonly pairing = new PairingService();
  private stopping = false;
  private busy = false;

  readonly record: BayaSessionRecord;
  private readonly adapter: AgentAdapter;
  private readonly openWorkspace: OpenWorkspace;

  constructor(record: BayaSessionRecord, adapter: AgentAdapter, openWorkspace: OpenWorkspace) {
    this.record = record;
    this.adapter = adapter;
    this.openWorkspace = openWorkspace;
    this.roomId = roomIdForBayaSession(record);
    this.relay = new OwnerRelayHost({
      roomId: this.roomId,
      roomMeta: { name: record.name, cwd: record.cwd },
      onMessage: (sender, message) => this.onMessage(sender, message),
      onFatal: (error) => process.stderr.write(`[baya] relay: ${error.message}\n`),
    });
  }

  async start(): Promise<void> {
    await this.adapter.start();
    this.relay.start();
  }

  stop(): void {
    if (this.stopping) return;
    this.stopping = true;
    this.relay.stop();
    this.adapter.close();
  }

  broadcast(message: ServerMessage): void {
    this.relay.broadcast(message);
  }

  setBusy(busy: boolean): void {
    this.busy = busy;
    this.relay.updateMeta({ working: busy });
  }

  setModel(model: string): void {
    this.relay.updateMeta({ model });
  }

  get isBusy(): boolean {
    return this.busy;
  }

  private onMessage(sender: PeerChannel, message: ClientMessage): void {
    void (async () => {
      if (message.type === "pair_request") {
        await this.pairing.handle(sender, message, {
          roomId: this.roomId,
          sessionName: this.record.name,
          sessionStartedAt: this.record.created_at,
          harnessName: `Baya · ${this.record.agent}`,
          harnessVersion: packageVersion(),
        });
        return;
      }
      if (
        message.type === "workspace_browse" ||
        message.type === "workspace_open" ||
        message.type === "session_files_browse" ||
        message.type === "session_file_read"
      ) {
        await handleWorkspaceRequest(sender, message, this.record.cwd, this.openWorkspace);
        return;
      }
      if (message.type === "sessions_inventory") {
        sender.send(sessionInventoryResponse(message.id));
        return;
      }
      await this.adapter.handle(sender, message);
    })().catch((error: unknown) => {
      const detail = error instanceof Error ? error.message : "Baya host request failed.";
      sender.send({
        type: "error",
        code: "internal_error",
        message: detail,
      });
    });
  }
}
