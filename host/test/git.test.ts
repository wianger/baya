import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import {
  gitCommit,
  gitDiff,
  gitPush,
  gitRevertFile,
  gitRevertHunk,
  gitStatus,
  type parseHunks,
} from "../src/workspace/git.ts";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function repo(): string {
  const dir = mkdtempSync(join(tmpdir(), "baya-git-"));
  dirs.push(dir);
  const g = (...args: string[]) => execFileSync("git", args, { cwd: dir, stdio: "pipe" });
  g("init", "-q", "-b", "main");
  g("config", "user.email", "test@example.com");
  g("config", "user.name", "Test");
  g("config", "commit.gpgsign", "false");
  const lines = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`);
  writeFileSync(join(dir, "a.txt"), `${lines.join("\n")}\n`);
  g("add", ".");
  g("commit", "-q", "-m", "start");
  return dir;
}

describe("reviewing changes", () => {
  test("lists changed and new files, and diffs one in hunks", async () => {
    const dir = repo();
    const text = readFileSync(join(dir, "a.txt"), "utf8")
      .replace("line 2\n", "line two\n")
      .replace("line 28\n", "line twenty-eight\n");
    writeFileSync(join(dir, "a.txt"), text);
    writeFileSync(join(dir, "new.txt"), "fresh\n");
    const status = await gitStatus(dir);
    expect(status["branch"]).toBe("main");
    expect(status["files"]).toEqual([
      { path: "a.txt", status: "M", added: 2, removed: 2 },
      { path: "new.txt", status: "?", added: 0, removed: 0 },
    ]);
    const diff = await gitDiff(dir, "a.txt");
    const hunks = diff["hunks"] as ReturnType<typeof parseHunks>;
    expect(hunks).toHaveLength(2);
    expect(hunks[0]!.lines).toContainEqual({ kind: "+", text: "line two" });
    const added = await gitDiff(dir, "new.txt");
    expect(added["untracked"]).toBe(true);
    expect(added["hunks"]).toEqual([
      expect.objectContaining({ lines: [{ kind: "+", text: "fresh" }] }),
    ]);
  });

  test("one hunk is reverted and the other kept", async () => {
    const dir = repo();
    const text = readFileSync(join(dir, "a.txt"), "utf8")
      .replace("line 2\n", "line two\n")
      .replace("line 28\n", "line twenty-eight\n");
    writeFileSync(join(dir, "a.txt"), text);
    const after = await gitRevertHunk(dir, "a.txt", 0);
    const now = readFileSync(join(dir, "a.txt"), "utf8");
    expect(now).toContain("line 2\n");
    expect(now).toContain("line twenty-eight\n");
    expect(after["hunks"]).toHaveLength(1);
  });

  test("a new file is reverted by deleting it", async () => {
    const dir = repo();
    writeFileSync(join(dir, "new.txt"), "fresh\n");
    await gitRevertFile(dir, "new.txt");
    expect(existsSync(join(dir, "new.txt"))).toBe(false);
    await expect(gitRevertFile(dir, "../outside.txt")).rejects.toThrow("not in this repository");
  });

  test("changes are committed and pushed", async () => {
    const dir = repo();
    const remote = mkdtempSync(join(tmpdir(), "baya-remote-"));
    dirs.push(remote);
    execFileSync("git", ["init", "-q", "--bare", remote]);
    execFileSync("git", ["remote", "add", "origin", remote], { cwd: dir });
    writeFileSync(join(dir, "new.txt"), "fresh\n");
    const { commit } = await gitCommit(dir, "Add new.txt");
    expect(commit).toMatch(/^[0-9a-f]+$/u);
    expect((await gitStatus(dir))["files"]).toEqual([]);
    await gitPush(dir);
    const pushed = execFileSync("git", ["log", "--format=%s", "main"], { cwd: remote }).toString();
    expect(pushed).toContain("Add new.txt");
  });

  test("a folder outside git says so", async () => {
    const dir = mkdtempSync(join(tmpdir(), "baya-nogit-"));
    dirs.push(dir);
    await expect(gitStatus(dir)).rejects.toThrow("not in a git repository");
  });
});

describe("worktrees", () => {
  test("makes one per agent outside the repository, and removes it", async () => {
    const { createWorktree, removeWorktree } = await import("../src/workspace/git.ts");
    const home = mkdtempSync(join(tmpdir(), "baya-home-"));
    dirs.push(home);
    const previous = process.env["HOME"];
    process.env["HOME"] = home;
    process.env["USERPROFILE"] = home;
    try {
      const dir = repo();
      const first = (await createWorktree(dir, "Claude Code")) as { root: string; branch: string };
      const second = (await createWorktree(dir, "Claude Code")) as { root: string; branch: string };
      expect(first.root.startsWith(join(home, ".baya", "worktrees"))).toBe(true);
      expect(first.branch).toMatch(/^baya\/claude-code-\d{12}$/u);
      expect(second.root).not.toBe(first.root);
      expect(readFileSync(join(first.root, "a.txt"), "utf8")).toContain("line 30");
      await removeWorktree(first.root);
      expect(existsSync(first.root)).toBe(false);
      const branches = execFileSync(
        "git",
        ["branch", "--list", "baya/*", "--format=%(refname:short)"],
        {
          cwd: dir,
        },
      )
        .toString()
        .trim()
        .split("\n");
      expect(branches).toEqual([second.branch]);
      await expect(removeWorktree(dir)).rejects.toThrow(/only the worktrees it made/u);
    } finally {
      process.env["HOME"] = previous;
      process.env["USERPROFILE"] = previous;
    }
  });
});
