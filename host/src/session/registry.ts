/** A conversation as the rest of the host reads it: an agent in a herdr pane. */
export type TitleSource = "prompt" | "generated" | "agent" | "user";

export interface SessionRecord {
  /** Baya's id; the ACP `sessionId` phones see. */
  id: string;
  cwd: string;
  /** Id of an agent in the config. */
  agent: string;
  title: string | null;
  titleSource: TitleSource | null;
  /** The agent's own session id. */
  agentSessionId: string | null;
  createdAt: number;
  updatedAt: number;
}

export function folderName(cwd: string): string {
  // Either separator: a Windows computer's paths read the same anywhere.
  return (
    cwd
      .replace(/[\\/]+$/u, "")
      .split(/[\\/]/u)
      .pop() || cwd
  );
}
