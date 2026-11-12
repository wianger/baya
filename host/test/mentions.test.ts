import { expect, test } from "vitest";
import { Editor } from "../src/cli/editor.ts";
import {
  type FileEntry,
  type Listing,
  Mentions,
  matching,
  mentionAt,
} from "../src/cli/mentions.ts";

const file = (name: string, dir = "/w"): FileEntry => ({
  name,
  path: `${dir}/${name}`,
  type: "file",
});
const folder = (name: string, dir = "/w"): FileEntry => ({
  name,
  path: `${dir}/${name}`,
  type: "directory",
});

test("an @ starts a mention only at the start of a word", () => {
  expect(mentionAt("look at @src/cl")).toBe("src/cl");
  expect(mentionAt("@")).toBe("");
  expect(mentionAt("mail me@example")).toBeNull();
  expect(mentionAt("@src/a.ts and")).toBeNull();
});

test("names that start with what is typed come before ones that contain it", () => {
  const entries = [file("attach.ts"), file("tui.ts"), file("cat.ts")];
  expect(matching(entries, "at").map((e) => e.name)).toEqual(["attach.ts", "cat.ts"]);
  expect(matching(entries, "").map((e) => e.name)).toEqual(["attach.ts", "tui.ts", "cat.ts"]);
  // What was built or installed comes last, unless it is what is typed.
  const root = [folder("dist"), folder("node_modules"), folder("src"), file("package.json")];
  expect(matching(root, "").map((e) => e.name)).toEqual([
    "src",
    "package.json",
    "dist",
    "node_modules",
  ]);
  expect(matching(root, "d")[0]!.name).toBe("dist");
});

test("folders are listed as they are typed, and a file chosen goes as a link", async () => {
  const tree: Record<string, FileEntry[]> = {
    "/w": [folder("src"), file("README.md")],
    "/w/src": [file("cli.ts", "/w/src")],
  };
  const asked: Array<string | undefined> = [];
  let changes = 0;
  const mentions = new Mentions(
    async (path): Promise<Listing> => {
      asked.push(path);
      return { root: "/w", path: path ?? "/w", entries: tree[path ?? "/w"]! };
    },
    () => changes++,
  );
  const settle = () => new Promise((r) => setTimeout(r, 0));

  expect(mentions.options("")).toBeNull();
  await settle();
  expect(mentions.options("")!.map((e) => e.name)).toEqual(["src", "README.md"]);

  const editor = new Editor();
  editor.insert("explain @s");
  const src = mentions.options("s")![0]!;
  editor.replaceBefore(2, mentions.complete("s", src));
  expect(editor.value).toBe("explain @src/");

  expect(mentions.options("src/")).toBeNull();
  await settle();
  const cli = mentions.options("src/")![0]!;
  editor.replaceBefore("@src/".length, mentions.complete("src/", cli));
  expect(editor.value).toBe("explain @src/cli.ts ");
  expect(asked).toEqual([undefined, "/w/src"]);
  expect(changes).toBe(2);

  expect(mentions.links(editor.value)).toEqual([
    { type: "resource_link", name: "cli.ts", uri: "file:///w/src/cli.ts" },
  ]);
  // A mention deleted from the text before sending is not sent.
  expect(mentions.links("explain this")).toEqual([]);
});
