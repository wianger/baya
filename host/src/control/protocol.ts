export type ControlCommand = "status" | "open" | "remove" | "pair" | "unpair" | "stop" | "attach";

export interface ControlRequest {
  token: string;
  id: string;
  command: ControlCommand;
  params?: Record<string, unknown>;
}

export interface ControlResponse {
  id: string;
  ok: boolean;
  data?: unknown;
  error?: string;
}

export interface ControlInfo {
  port: number;
  token: string;
  pid: number;
  started_at: number;
}

/** One session as `baya status` shows it. */
export interface SessionStatus {
  id: string;
  title: string;
  cwd: string;
  agent: string;
  running: boolean;
  working: boolean;
  error: string | null;
}

export interface HostStatus {
  pid: number;
  version: string;
  started_at: number;
  /** Short Tailscale name phones can type, when Tailscale is on. */
  tailnet: string | null;
  /** Where phones connect, when `tailscale serve` routes to this host. */
  direct: string | null;
  phones_connected: number;
  sessions: SessionStatus[];
}
