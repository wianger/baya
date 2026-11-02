export type ControlCommand = "status" | "list" | "open" | "remove" | "pair" | "stop";

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
