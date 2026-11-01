/**
 * Shared, SDK-independent contract for opening an agent in a host folder.
 * Known ids retain completion while the open string arm lets the desktop
 * advertise adapters added in later releases without an app enum migration.
 */
export type WorkspaceAgent =
  | "pi"
  | "codex"
  | "deepseek"
  | (string & {});

export interface WorkspaceAgentInfo {
  id: WorkspaceAgent;
  name: string;
  available: boolean;
  description?: string;
  reason?: string;
}

export interface WorkspaceDirectory {
  path: string;
  parent: string | null;
  home: string;
  roots: string[];
  directories: Array<{ name: string; path: string }>;
  agents: WorkspaceAgentInfo[];
  truncated: boolean;
}

export interface OpenedWorkspace {
  id: string;
  cwd: string;
  name: string;
  agent: WorkspaceAgent;
  room_id: string;
  /** True when the agent was already registered before this request. */
  existing: boolean;
}

export interface SessionFileEntry {
  name: string;
  path: string;
  type: "file" | "directory";
  size: number | null;
  modified_at: number | null;
}

export interface SessionDirectory {
  root: string;
  path: string;
  parent: string | null;
  entries: SessionFileEntry[];
  truncated: boolean;
}

export interface SessionFileContent {
  name: string;
  path: string;
  size: number;
  modified_at: number;
  content: string | null;
  binary: boolean;
  truncated: boolean;
}

export type WorkspaceRequest =
  | { type: "workspace_browse"; id: string; path?: string; show_hidden?: boolean }
  | { type: "workspace_open"; id: string; path: string; agent: WorkspaceAgent };

export type WorkspaceReply =
  | { type: "workspace_listing"; in_reply_to: string; directory: WorkspaceDirectory }
  | { type: "workspace_opened"; in_reply_to: string; workspace: OpenedWorkspace }
  | { type: "workspace_error"; in_reply_to: string; error: string };

/** Read-only access to files below the cwd of the authenticated session. */
export type SessionFilesRequest =
  | { type: "session_files_browse"; id: string; path?: string; show_hidden?: boolean }
  | { type: "session_file_read"; id: string; path: string };

export type SessionFilesReply =
  | { type: "session_files_listing"; in_reply_to: string; directory: SessionDirectory }
  | { type: "session_file_content"; in_reply_to: string; file: SessionFileContent }
  | { type: "session_file_error"; in_reply_to: string; error: string };
