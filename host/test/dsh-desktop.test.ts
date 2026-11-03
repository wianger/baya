import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { DshDesktop, isDsh } from "../src/integrations/dsh_desktop.ts";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function setup() {
  const root = mkdtempSync(join(tmpdir(), "baya-dsh-"));
  dirs.push(root);
  const dshHome = join(root, "dsh");
  const project = join(root, "project");
  mkdirSync(join(dshHome, "storages"), { recursive: true });
  mkdirSync(project);
  const file = join(dshHome, "storages", "workspace.json");
  writeFileSync(
    file,
    JSON.stringify({
      unit: { name: "workspace", version: 2 },
      global: { initialized: true, workspaceIds: ["w1"], archivedSessionIds: [] },
      tables: {
        workspaces: {
          w1: {
            path: join(root, "other"),
            title: "other",
            sessionIds: ["s0"],
            createdAt: "x",
            updatedAt: "x",
          },
        },
      },
    }),
  );
  const definition = {
    id: "deepseek",
    name: "DeepSeek",
    command: ["dsh", "--profile", "acp"],
    env: { DSH_HOME: dshHome },
  };
  return { root, file, project, definition, pending: join(root, "pending.json") };
}

const read = (file: string) => JSON.parse(readFileSync(file, "utf8"));

describe("DeepSeek desktop registration", () => {
  test("recognises dsh however it is installed", () => {
    expect(isDsh({ id: "d", name: "D", command: ["dsh"] })).toBe(true);
    expect(isDsh({ id: "d", name: "D", command: ["C:\\DeepSeek Harness\\bin\\dsh.cmd"] })).toBe(
      true,
    );
    expect(isDsh({ id: "c", name: "C", command: ["codex-acp"] })).toBe(false);
  });

  test("a session gets its folder's workspace while the app is closed", () => {
    const { file, project, definition, pending } = setup();
    new DshDesktop(pending, () => false).register(definition, "s1", project);
    const data = read(file);
    const created = Object.entries(data.tables.workspaces).find(([id]) => id !== "w1")!;
    expect(created[1]).toMatchObject({ title: "project", sessionIds: ["s1"] });
    expect(data.global.workspaceIds).toEqual(["w1", created[0]]);
    expect(data.global.initialized).toBe(true);
    expect(read(pending)).toEqual([]);
    // A second session in the folder joins the same workspace, newest first.
    new DshDesktop(pending, () => false).register(definition, "s2", project);
    expect(read(file).tables.workspaces[created[0]].sessionIds).toEqual(["s2", "s1"]);
  });

  test("nothing is written while the app is open; it is written once it closes", () => {
    const { file, project, definition, pending } = setup();
    let running = true;
    const desktop = new DshDesktop(pending, () => running);
    const before = readFileSync(file, "utf8");
    desktop.register(definition, "s1", project);
    expect(readFileSync(file, "utf8")).toBe(before);
    expect(read(pending)).toHaveLength(1);
    desktop.register(definition, "gone", project);
    desktop.forget("gone");
    running = false;
    desktop.flush();
    expect(JSON.stringify(read(file))).toContain('"s1"');
    expect(JSON.stringify(read(file))).not.toContain('"gone"');
  });
});
