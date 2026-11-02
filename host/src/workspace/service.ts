import type { PeerChannel } from "../transport/peer_channel.ts";
import { browseDirectory, resolveDirectory } from "./directories.ts";
import { browseSessionFiles, readSessionFile } from "./session_files.ts";
import type { OpenedWorkspace, SessionFilesRequest, WorkspaceRequest } from "./types.ts";

export type OpenWorkspace = (path: string, agent: unknown) => Promise<OpenedWorkspace>;

/**
 * Read-only workspace and session-file operations shared by every adapter.
 * The manager supplies `openWorkspace`; Pi plugins are no longer involved.
 */
export async function handleWorkspaceRequest(
  sender: PeerChannel,
  message: WorkspaceRequest | SessionFilesRequest,
  cwd: string,
  openWorkspace: OpenWorkspace,
): Promise<void> {
  if (typeof message.id !== "string" || message.id.length === 0 || message.id.length > 200) return;

  try {
    switch (message.type) {
      case "workspace_browse": {
        const directory = await browseDirectory(message.path, message.show_hidden === true);
        sender.send({ type: "workspace_listing", in_reply_to: message.id, directory });
        return;
      }
      case "workspace_open": {
        const path = await resolveDirectory(message.path);
        const workspace = await openWorkspace(path, message.agent);
        sender.send({ type: "workspace_opened", in_reply_to: message.id, workspace });
        return;
      }
      case "session_files_browse": {
        const directory = await browseSessionFiles(cwd, message.path, message.show_hidden === true);
        sender.send({ type: "session_files_listing", in_reply_to: message.id, directory });
        return;
      }
      case "session_file_read": {
        const file = await readSessionFile(cwd, message.path);
        sender.send({ type: "session_file_content", in_reply_to: message.id, file });
      }
    }
  } catch (error) {
    const detail = error instanceof Error ? error.message : "Could not open this path.";
    const type =
      message.type === "session_files_browse" || message.type === "session_file_read"
        ? "session_file_error"
        : "workspace_error";
    sender.send({ type, in_reply_to: message.id, error: detail });
  }
}
