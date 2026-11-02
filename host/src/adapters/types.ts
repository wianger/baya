import type { ClientMessage, ServerMessage } from "../protocol/types.ts";
import type { PeerChannel } from "../transport/peer_channel.ts";
import type { WorkspaceAgent } from "../workspace/types.ts";

export interface AdapterOptions {
  cwd: string;
  name: string;
  sessionId: string;
  nativeSessionId?: string;
  broadcast: (message: ServerMessage) => void;
  onBusy?: (busy: boolean) => void;
  onModel?: (model: string) => void;
  onClosed?: (error: Error) => void;
  onNativeSessionId?: (sessionId: string) => void;
}

export interface AgentAdapter {
  readonly agent: WorkspaceAgent;
  readonly isBusy: boolean;
  start(): Promise<void>;
  handle(sender: PeerChannel, message: ClientMessage): Promise<void>;
  close(): void;
}
