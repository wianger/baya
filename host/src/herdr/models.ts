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

type Json = Record<string, unknown>;

/** What an agent says of itself over ACP: its settings and its commands. */
export interface AgentSettings {
  options: Json[];
  commands: Json[];
}

/** Asks agent [id] (Baya's name for it) for its settings over ACP. */
type Fetch = (id: string) => Promise<AgentSettings>;
let fetcher: Fetch | null = null;
const asked = new Map<string, Promise<Json[]>>();
const told = new Map<string, Json[]>();
const toldCommands = new Map<string, Json[]>();

export function useModelFetcher(fetch: Fetch): void {
  fetcher = fetch;
}

/** herdr calls Claude Code `claude-code`; Baya calls it `claude`. */
const agentId = (agent: string) => (agent === "claude-code" ? "claude" : agent);

/** The settings a pane's TUI changes with a command: its model, its thinking. */
const TYPED = new Set(["model", "thought_level"]);

function fromAgent(agent: string): Promise<Json[]> {
  const id = agentId(agent);
  if (!fetcher) return Promise.resolve([]);
  let pending = asked.get(id);
  if (!pending) {
    pending = fetcher(id)
      .catch((): AgentSettings => ({ options: [], commands: [] }))
      .then(({ options: all, commands }) => {
        if (commands.length) toldCommands.set(id, commands);
        const options = all.filter(
          (o) => o["type"] === "select" && TYPED.has(String(o["category"] ?? o["id"])),
        );
        if (options.length) told.set(id, options);
        else asked.delete(id);
        return options;
      });
    asked.set(id, pending);
  }
  return pending;
}

/** The model choices in ACP config options (grouped or not). */
export function choicesFrom(options: Json[]): ModelChoice[] {
  const model = options.find((o) => o["category"] === "model" || o["id"] === "model");
  const flat = (items: unknown): ModelChoice[] =>
    (Array.isArray(items) ? (items as Json[]) : []).flatMap((item) =>
      Array.isArray(item["options"])
        ? flat(item["options"])
        : typeof item["value"] === "string"
          ? [{ value: item["value"], name: String(item["name"] ?? item["value"]) }]
          : [],
    );
  return model ? flat(model["options"]) : [];
}

/** Without the agent's own word: Claude Code's aliases, Pi's catalog. */
async function fallback(agent: string): Promise<Json[]> {
  const models =
    agent === "claude" || agent === "claude-code"
      ? CLAUDE
      : agent === "pi"
        ? await listPiModels()
        : [];
  return models.length ? [modelOption(models, null)] : [];
}

/**
 * A pane agent's settings the phone can change, as the agent gives them;
 * null while it is still being asked (they follow, from [paneOptionsLater]).
 */
/** The agent's own slash commands, once it has said them. */
export function paneCommands(agent: string): Json[] | null {
  return toldCommands.get(agentId(agent)) ?? null;
}

export async function paneCommandsLater(agent: string): Promise<Json[]> {
  await fromAgent(agent);
  return toldCommands.get(agentId(agent)) ?? [];
}

export function paneOptions(agent: string): Json[] | null {
  return told.get(agentId(agent)) ?? null;
}

export async function paneOptionsLater(agent: string): Promise<Json[]> {
  const own = await fromAgent(agent);
  return own.length ? own : fallback(agent);
}

/** [options] with the values chosen here, or found in the record, as current. */
export function withCurrent(options: Json[], chosen: Record<string, string>): Json[] {
  return options.map((o) => {
    const id = String(o["id"]);
    const value = chosen[id] ?? chosen[String(o["category"])];
    return value ? { ...o, currentValue: value } : o;
  });
}

/** What the agent's TUI is typed to change [option] to [value]. */
export function optionCommand(agent: string, option: Json, value: string): string | null {
  const category = String(option["category"] ?? option["id"]);
  if (category === "model") return `/model ${value}`;
  if (category === "thought_level") {
    if (agent === "pi") return `/thinking ${value}`;
    if (agent === "claude" || agent === "claude-code") return `/effort ${value}`;
  }
  return null;
}

/** Whether [value] is one of [option]'s choices. */
export function offers(option: Json, value: string): boolean {
  const flat = (items: unknown): boolean =>
    (Array.isArray(items) ? (items as Json[]) : []).some((item) =>
      Array.isArray(item["options"]) ? flat(item["options"]) : item["value"] === value,
    );
  return flat(option["options"]);
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
