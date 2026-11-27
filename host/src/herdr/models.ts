/**
 * The models an agent's TUI switches between with `/model <name>`, for a
 * conversation in a pane: Claude Code's aliases, Pi's catalog
 * (`pi --list-models`, read once). Others have none to offer.
 */
import { exec } from "node:child_process";

export interface ModelChoice {
  value: string;
  name: string;
}

const CLAUDE: ModelChoice[] = [
  { value: "default", name: "Default" },
  { value: "opus", name: "Opus" },
  { value: "sonnet", name: "Sonnet" },
  { value: "haiku", name: "Haiku" },
];

let piModels: Promise<ModelChoice[]> | null = null;
let piKnown: ModelChoice[] | null = null;

/** `pi --list-models`: a table of provider, model, context… */
export function parsePiModels(table: string): ModelChoice[] {
  return table
    .split(/\r?\n/u)
    .slice(1)
    .map((line) => line.trim().split(/\s+/u))
    .filter((cols) => cols.length >= 2 && cols[0] && cols[1])
    .map(([provider, model]) => ({ value: `${provider}/${model}`, name: model! }));
}

function listPiModels(): Promise<ModelChoice[]> {
  piModels ??= new Promise((resolve) => {
    exec("pi --list-models", { timeout: 60_000, windowsHide: true }, (error, stdout) => {
      if (error) piModels = null;
      else piKnown = parsePiModels(`${stdout}`);
      resolve(piKnown ?? []);
    });
  });
  return piModels;
}

/** The models known now, without waiting; null while they are still read. */
export function knownModels(agent: string): ModelChoice[] | null {
  if (agent === "claude" || agent === "claude-code") return CLAUDE;
  if (agent === "pi") {
    if (!piKnown) void listPiModels();
    return piKnown;
  }
  return [];
}

export async function modelsFor(agent: string): Promise<ModelChoice[]> {
  if (agent === "claude" || agent === "claude-code") return CLAUDE;
  if (agent === "pi") return listPiModels();
  return [];
}

/** The ACP config option the phone's model picker shows. */
export function modelOption(
  choices: ModelChoice[],
  current: string | null,
): Record<string, unknown> {
  return {
    id: "model",
    name: "Model",
    category: "model",
    type: "select",
    currentValue: current ?? choices[0]?.value ?? "",
    options: choices,
  };
}
