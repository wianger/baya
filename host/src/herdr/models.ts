/**
 * The models an agent's TUI switches between with `/model <name>`, for a
 * conversation in a pane: the agent's own list, as it gives it over ACP
 * (what Baya's own sessions of it offer), read once; else Claude Code's
 * aliases or Pi's catalog (`pi --list-models`).
 */
import { exec } from "node:child_process";

export interface ModelChoice {
  value: string;
  name: string;
  /** Tokens its context holds, where the catalog says. */
  context?: number;
}

/** `1.0M`, `258.6K`, `128000`: tokens. */
const tokens = (text: string | undefined): number | undefined => {
  const m = /^([\d.]+)([KM]?)$/iu.exec(text ?? "");
  if (!m) return undefined;
  const scale = m[2]?.toUpperCase() === "M" ? 1_000_000 : m[2] ? 1_000 : 1;
  return Math.round(Number(m[1]) * scale);
};

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
    .map(([provider, model, context]) => {
      const size = tokens(context);
      return { value: `${provider}/${model}`, name: model!, ...(size ? { context: size } : {}) };
    });
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
  const own = told.get(agentId(agent));
  if (own) return own;
  // Asked once; until it answers, the list comes later.
  if (fetcher && (agent === "claude" || agent === "claude-code" || agent === "pi")) {
    return null;
  }
  if (agent === "claude" || agent === "claude-code") return CLAUDE;
  if (agent === "pi") {
    if (!piKnown) void listPiModels();
    return piKnown;
  }
  return [];
}

/** Asks agent [id] (Baya's name for it) for its models over ACP. */
type Fetch = (id: string) => Promise<ModelChoice[]>;
let fetcher: Fetch | null = null;
const asked = new Map<string, Promise<ModelChoice[]>>();
const told = new Map<string, ModelChoice[]>();

export function useModelFetcher(fetch: Fetch): void {
  fetcher = fetch;
}

/** herdr calls Claude Code `claude-code`; Baya calls it `claude`. */
const agentId = (agent: string) => (agent === "claude-code" ? "claude" : agent);

function fromAgent(agent: string): Promise<ModelChoice[]> {
  const id = agentId(agent);
  if (!fetcher) return Promise.resolve([]);
  let pending = asked.get(id);
  if (!pending) {
    pending = fetcher(id)
      .catch(() => [])
      .then((list) => {
        if (list.length) told.set(id, list);
        else asked.delete(id);
        return list;
      });
    asked.set(id, pending);
  }
  return pending;
}

/** The choices in an ACP model option (grouped or not), or `models`. */
export function choicesFrom(result: Record<string, unknown>): ModelChoice[] {
  const options = Array.isArray(result["configOptions"]) ? (result["configOptions"] as Json[]) : [];
  const model = options.find((o) => o["category"] === "model" || o["id"] === "model");
  const flat = (items: unknown): ModelChoice[] =>
    (Array.isArray(items) ? (items as Json[]) : []).flatMap((item) =>
      Array.isArray(item["options"])
        ? flat(item["options"])
        : typeof item["value"] === "string"
          ? [{ value: item["value"], name: String(item["name"] ?? item["value"]) }]
          : [],
    );
  if (model) return flat(model["options"]);
  const models = result["models"] as Json | undefined;
  return ((models?.["availableModels"] as Json[] | undefined) ?? []).flatMap((m) =>
    typeof m["modelId"] === "string"
      ? [{ value: m["modelId"], name: String(m["name"] ?? m["modelId"]) }]
      : [],
  );
}

type Json = Record<string, unknown>;

export async function modelsFor(agent: string): Promise<ModelChoice[]> {
  const own = await fromAgent(agent);
  if (own.length) return own;
  if (agent === "claude" || agent === "claude-code") return CLAUDE;
  if (agent === "pi") return listPiModels();
  return [];
}

/** The context [model] (`provider/id`) holds, once Pi's catalog is read. */
export function piContext(model: string | null): number {
  if (!model) return 0;
  if (!piKnown) void listPiModels();
  return piKnown?.find((m) => m.value === model)?.context ?? 0;
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
    options: choices.map(({ value, name }) => ({ value, name })),
  };
}
