import type { ThinkingLevel } from "./types.ts";

export const THINKING_LEVELS = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
  "ultra",
] as const satisfies readonly ThinkingLevel[];

const ALIASES: Readonly<Record<string, ThinkingLevel>> = {
  off: "off",
  none: "off",
  disabled: "off",
  minimal: "minimal",
  min: "minimal",
  low: "low",
  medium: "medium",
  med: "medium",
  high: "high",
  xhigh: "xhigh",
  "x high": "xhigh",
  "extra high": "xhigh",
  extrahigh: "xhigh",
  max: "max",
  maximum: "max",
  ultra: "ultra",
};

/** Convert one provider value to the canonical mobile wire vocabulary. */
export function thinkingLevel(value: unknown): ThinkingLevel | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().toLowerCase().replaceAll("_", " ").replaceAll("-", " ");
  return ALIASES[normalized];
}

/**
 * Convert option-like provider records (`{ value }`, `{ name }`, or Codex's
 * `{ reasoningEffort }`) to a deduplicated, SDK-ordered level list.
 */
export function thinkingLevelsFromOptions(values: readonly unknown[]): ThinkingLevel[] {
  const found = new Set<ThinkingLevel>();
  for (const raw of values) {
    if (typeof raw === "string") {
      const level = thinkingLevel(raw);
      if (level) found.add(level);
      continue;
    }
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
    const entry = raw as Record<string, unknown>;
    for (const candidate of [
      entry["reasoningEffort"],
      entry["effort"],
      entry["value"],
      entry["name"],
      entry["id"],
    ]) {
      const level = thinkingLevel(candidate);
      if (level) {
        found.add(level);
        break;
      }
    }
  }
  return THINKING_LEVELS.filter((level) => found.has(level));
}

/**
 * Match Pi's `getSupportedThinkingLevels`: base levels are available unless
 * explicitly mapped to null; extended levels require an explicit mapping.
 */
export function thinkingLevelsFromMap(raw: unknown, reasoning: boolean): ThinkingLevel[] {
  if (!reasoning) return [];
  const map =
    raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  return THINKING_LEVELS.filter((level) => {
    if (map[level] === null) return false;
    if (level === "xhigh" || level === "max" || level === "ultra") {
      return map[level] !== undefined;
    }
    return true;
  });
}
