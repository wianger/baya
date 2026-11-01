import type { WorkspaceAgent } from "./types.js";

/** Catalog of implemented adapters. Register a new entry only after its runner
 * is connected; publishing a name alone must not imply runtime support.
 */
export const workspaceAgents: ReadonlyArray<{
  id: WorkspaceAgent; name: string; command: string; description: string;
}> = [
  { id: "pi", name: "Pi", command: "pi", description: "Pi coding agent via its native RPC mode" },
  { id: "codex", name: "Codex", command: "codex", description: "Codex coding agent" },
  { id: "deepseek", name: "DeepSeek", command: "dsh", description: "DeepSeek Harness" },
];

export function workspaceAgentDefinition(id: unknown) {
  return typeof id === "string"
    ? workspaceAgents.find((agent) => agent.id === id)
    : undefined;
}
