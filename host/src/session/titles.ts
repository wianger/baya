/**
 * Short titles for conversations whose agent does not name them (Pi): one
 * request to Pi's own default model, out of any session and without tools,
 * asked for a few words in the language of the first message, the way
 * Claude Code and Codex title theirs.
 */
import { execFile } from "node:child_process";
import { tmpdir } from "node:os";
import { promisify } from "node:util";
import { spawnPlan } from "../process/spawn.ts";
import { findExecutable } from "../workspace/directories.ts";

const run = promisify(execFile);

const INSTRUCTIONS =
  "You name conversations. Reply with only a short title, 3 to 7 words (or up to 16 " +
  "characters in Chinese or Japanese), in the same language as the message. " +
  "No quotes, no trailing punctuation, nothing else.";

/** A title as a list shows it: one line, no quotes or markdown, not too long. */
export function cleanTitle(raw: string): string | null {
  const line = raw
    .split(/\r?\n/u)
    .map((l) => l.trim())
    .find((l) => l !== "");
  if (!line) return null;
  const title = line
    .replace(/^(title|标题)\s*[:：]\s*/iu, "")
    .replace(/\*\*/gu, "")
    .replace(/^[#>*\-\s]+/u, "")
    .replace(/^["'“”‘’「『《]+|["'“”‘’」』》]+$/gu, "")
    .replace(/[.。!！?？;；,，:：\s]+$/u, "")
    .replace(/\s+/gu, " ")
    .trim();
  if (!title) return null;
  return [...title].length > 48 ? `${[...title].slice(0, 47).join("")}…` : title;
}

type Generator = (text: string) => Promise<string | null>;

/** Pi, asked once. Null when Pi is not here or does not answer in time. */
const piTitle: Generator = async (text) => {
  const pi = await findExecutable("pi");
  if (!pi) return null;
  const plan = spawnPlan(pi, [
    "-p",
    "--no-session",
    "--no-tools",
    "--thinking",
    "off",
    "--system-prompt",
    INSTRUCTIONS,
    text.slice(0, 1000),
  ]);
  try {
    const { stdout } = await run(plan.command, plan.prefixArgs, {
      cwd: tmpdir(),
      timeout: 60_000,
      windowsHide: true,
      windowsVerbatimArguments: plan.windowsVerbatimArguments,
    });
    return cleanTitle(stdout);
  } catch {
    return null;
  }
};

let generator: Generator = piTitle;

/** A short title for a conversation that begins with [text]. */
export function generateTitle(text: string): Promise<string | null> {
  return text.trim() ? generator(text) : Promise.resolve(null);
}

/** For tests: titles from somewhere other than Pi. */
export function useTitleGenerator(next: Generator | null): void {
  generator = next ?? piTitle;
}
