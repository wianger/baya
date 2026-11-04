/**
 * Reviewing an agent's work from the phone: what changed in the session's
 * repository, each file's diff in hunks, reverting a hunk or a file, and
 * committing, pushing and opening a pull request.
 */
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { rm } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import { promisify } from "node:util";
import { RpcError } from "../acp/jsonrpc.ts";

const run = promisify(execFile);
const MAX_BUFFER = 32 * 1024 * 1024;

type Json = Record<string, unknown>;

async function git(cwd: string, args: string[], input?: string): Promise<string> {
  try {
    if (input !== undefined) {
      return await new Promise((done, fail) => {
        const child = execFile(
          "git",
          args,
          { cwd, maxBuffer: MAX_BUFFER, windowsHide: true },
          (error, stdout, stderr) =>
            error ? fail(Object.assign(error, { stderr })) : done(stdout),
        );
        child.stdin?.end(input);
      });
    }
    const { stdout } = await run("git", args, { cwd, maxBuffer: MAX_BUFFER, windowsHide: true });
    return stdout;
  } catch (error) {
    const stderr = String((error as { stderr?: unknown }).stderr ?? "").trim();
    throw new RpcError(-32000, stderr || (error as Error).message);
  }
}

async function root(cwd: string): Promise<string> {
  try {
    return (
      await run("git", ["rev-parse", "--show-toplevel"], { cwd, windowsHide: true })
    ).stdout.trim();
  } catch {
    throw new RpcError(-32000, "This folder is not in a git repository.", { reason: "not_git" });
  }
}

/** [path] relative to the repository, refusing anything outside it. */
function inside(repo: string, path: string): string {
  const rel = relative(repo, isAbsolute(path) ? path : resolve(repo, path));
  if (!rel || rel.startsWith("..") || isAbsolute(rel)) {
    throw RpcError.invalidParams("That file is not in this repository.");
  }
  return rel.split("\\").join("/");
}

export interface DiffHunk {
  header: string;
  oldStart: number;
  newStart: number;
  lines: { kind: "+" | "-" | " "; text: string }[];
}

/** Hunks of one file's unified diff; the file headers are left out. */
export function parseHunks(patch: string): DiffHunk[] {
  const hunks: DiffHunk[] = [];
  for (const line of patch.split("\n")) {
    const header = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/u.exec(line);
    if (header) {
      hunks.push({
        header: line,
        oldStart: Number(header[1]),
        newStart: Number(header[2]),
        lines: [],
      });
      continue;
    }
    const hunk = hunks.at(-1);
    if (!hunk || line.startsWith("\\")) continue;
    const kind = line[0];
    if (kind === "+" || kind === "-" || kind === " ") {
      hunk.lines.push({ kind, text: line.slice(1) });
    }
  }
  return hunks;
}

/** The file headers of a unified diff, up to its first hunk. */
function fileHeader(patch: string): string {
  const at = patch.indexOf("\n@@");
  return at === -1 ? patch : patch.slice(0, at + 1);
}

async function filePatch(repo: string, path: string, untracked: boolean): Promise<string> {
  if (!untracked) return git(repo, ["diff", "--no-color", "--no-ext-diff", "HEAD", "--", path]);
  // An untracked file: its whole content, as added.
  try {
    await run("git", ["diff", "--no-color", "--no-index", "--", "/dev/null", path], {
      cwd: repo,
      maxBuffer: MAX_BUFFER,
      windowsHide: true,
    });
    return "";
  } catch (error) {
    // --no-index exits 1 when the files differ, which is the point.
    return String((error as { stdout?: unknown }).stdout ?? "");
  }
}

async function untrackedFiles(repo: string): Promise<Set<string>> {
  const out = await git(repo, ["ls-files", "--others", "--exclude-standard", "-z"]);
  return new Set(out.split("\0").filter(Boolean));
}

export async function gitStatus(cwd: string): Promise<Json> {
  const repo = await root(cwd);
  const branchLines = (await git(repo, ["status", "--porcelain=v2", "--branch", "-z"]))
    .split("\0")
    .filter((line) => line.startsWith("# "));
  const value = (key: string) =>
    branchLines.find((line) => line.startsWith(`# ${key} `))?.slice(key.length + 3);
  const [ahead, behind] = (value("branch.ab") ?? "+0 -0")
    .split(" ")
    .map((n) => Math.abs(Number(n)));
  const counts = new Map<string, [number, number]>();
  for (const line of (await git(repo, ["diff", "--numstat", "HEAD"]).catch(() => "")).split("\n")) {
    const [added, removed, path] = line.split("\t");
    if (path) counts.set(path, [Number(added) || 0, Number(removed) || 0]);
  }
  const files: Json[] = [];
  const names = await git(repo, ["diff", "--name-status", "HEAD"]).catch(() => "");
  for (const line of names.split("\n")) {
    const [status, ...rest] = line.split("\t");
    const path = rest.at(-1);
    if (!status || !path) continue;
    const [added, removed] = counts.get(path) ?? [0, 0];
    files.push({ path, status: status[0], added, removed });
  }
  for (const path of await untrackedFiles(repo)) {
    files.push({ path, status: "?", added: 0, removed: 0 });
  }
  return {
    root: repo,
    branch: value("branch.head") ?? "HEAD",
    upstream: value("branch.upstream") ?? null,
    ahead: ahead ?? 0,
    behind: behind ?? 0,
    files,
  };
}

export async function gitDiff(cwd: string, path: string): Promise<Json> {
  const repo = await root(cwd);
  const file = inside(repo, path);
  const untracked = (await untrackedFiles(repo)).has(file);
  return { path: file, untracked, hunks: parseHunks(await filePatch(repo, file, untracked)) };
}

/** Undoes one hunk of [path] in the working tree. */
export async function gitRevertHunk(cwd: string, path: string, index: number): Promise<Json> {
  const repo = await root(cwd);
  const file = inside(repo, path);
  if ((await untrackedFiles(repo)).has(file)) return gitRevertFile(cwd, path);
  const patch = await filePatch(repo, file, false);
  const hunks = patch.split(/\n(?=@@ )/u).slice(1);
  const hunk = hunks[index];
  if (hunk === undefined) throw RpcError.invalidParams("That change is no longer there.");
  const single = `${fileHeader(patch)}${hunk.endsWith("\n") ? hunk : `${hunk}\n`}`;
  await git(repo, ["apply", "--reverse", "--recount", "-"], single);
  return gitDiff(cwd, path);
}

/** Puts [path] back as it is in HEAD; a file new since then is deleted. */
export async function gitRevertFile(cwd: string, path: string): Promise<Json> {
  const repo = await root(cwd);
  const file = inside(repo, path);
  if ((await untrackedFiles(repo)).has(file)) {
    await rm(join(repo, file), { force: true });
  } else {
    await git(repo, ["restore", "--source=HEAD", "--staged", "--worktree", "--", file]);
  }
  return {};
}

export async function gitCommit(cwd: string, message: string): Promise<Json> {
  const repo = await root(cwd);
  if (!message.trim()) throw RpcError.invalidParams("A commit needs a message.");
  await git(repo, ["add", "--all"]);
  await git(repo, ["commit", "--quiet", "-m", message]);
  const sha = (await git(repo, ["rev-parse", "--short", "HEAD"])).trim();
  return { commit: sha };
}

export async function gitPush(cwd: string): Promise<Json> {
  const repo = await root(cwd);
  const status = await gitStatus(cwd);
  await git(
    repo,
    status["upstream"]
      ? ["push", "--quiet"]
      : ["push", "--quiet", "--set-upstream", "origin", "HEAD"],
  );
  return {};
}

/** Opens a pull request for the current branch with the GitHub CLI. */
export async function openPullRequest(cwd: string, title: string, body: string): Promise<Json> {
  const repo = await root(cwd);
  try {
    const { stdout } = await run("gh", ["pr", "create", "--title", title, "--body", body || " "], {
      cwd: repo,
      windowsHide: true,
    });
    return { url: stdout.trim().split("\n").at(-1) ?? "" };
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      throw new RpcError(
        -32000,
        "Opening a pull request needs the GitHub CLI (gh) on this computer.",
      );
    }
    const stderr = String((error as { stderr?: unknown }).stderr ?? "").trim();
    throw new RpcError(-32000, stderr || (error as Error).message);
  }
}

/** A name safe for a branch and a folder. */
function worktreeSlug(name: string): string {
  return (
    name
      .toLowerCase()
      .replace(/[^a-z0-9]+/gu, "-")
      .replace(/^-+|-+$/gu, "")
      .slice(0, 32) || "agent"
  );
}

/**
 * A new worktree of [cwd]'s repository on its own branch, from HEAD, so
 * agents working side by side never edit the same files. It lives under
 * `~/.baya/worktrees`, outside the repository; the result names the folder
 * matching [cwd] inside it.
 */
export async function createWorktree(cwd: string, name: string): Promise<Json> {
  const repo = await root(cwd);
  const id = createHash("sha256").update(repo).digest("hex").slice(0, 8);
  const parent = join(homedir(), ".baya", "worktrees", `${worktreeSlug(basename(repo))}-${id}`);
  const stamp = new Date().toISOString().slice(0, 16).replace(/[-:T]/gu, "");
  let slug = `${worktreeSlug(name)}-${stamp}`;
  for (let n = 2; existsSync(join(parent, slug)); n++) slug = `${worktreeSlug(name)}-${stamp}-${n}`;
  const path = join(parent, slug);
  const branch = `baya/${slug}`;
  await git(repo, ["worktree", "add", "--quiet", "-b", branch, path, "HEAD"]);
  return { root: path, path: join(path, relative(repo, resolve(cwd))), branch };
}

/** Removes a worktree [createWorktree] made, and its branch. */
export async function removeWorktree(path: string): Promise<Json> {
  const worktree = await root(path);
  const rel = relative(join(homedir(), ".baya", "worktrees"), worktree);
  if (!rel || rel.startsWith("..") || isAbsolute(rel)) {
    throw RpcError.invalidParams("Baya removes only the worktrees it made.");
  }
  const branch = (await git(worktree, ["branch", "--show-current"])).trim();
  const common = (
    await git(worktree, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
  ).trim();
  await git(worktree, ["worktree", "remove", "--force", worktree]);
  if (branch.startsWith("baya/")) {
    await git(resolve(common, ".."), ["branch", "-D", branch]).catch(() => "");
  }
  return {};
}
