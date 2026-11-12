import { expect, test } from "vitest";
import { toolLabel } from "../src/cli/attach.ts";
import { Editor } from "../src/cli/editor.ts";
import { diffRows } from "../src/cli/tui.ts";

test("the editor wraps wide characters and finds its caret", () => {
  const editor = new Editor();
  editor.insert("你好世界abc");
  // 4 wide characters are 8 columns.
  expect(editor.layout(6)).toEqual({ rows: ["你好世", "界abc"], row: 1, column: 5 });
  editor.home();
  expect(editor.layout(6)).toMatchObject({ row: 0, column: 0 });
  editor.right();
  editor.right();
  expect(editor.layout(6)).toMatchObject({ row: 0, column: 4 });
});

test("lines, killing and words", () => {
  const editor = new Editor();
  editor.insert("first line\nsecond word");
  expect(editor.onLastLine).toBe(true);
  expect(editor.onFirstLine).toBe(false);
  editor.killWord();
  expect(editor.value).toBe("first line\nsecond ");
  editor.killBefore();
  expect(editor.value).toBe("first line\n");
  editor.backspace();
  editor.home();
  editor.killAfter();
  expect(editor.value).toBe("");
  // Control characters a terminal may send are not text.
  editor.insert("a\u0007b\r\nc");
  expect(editor.value).toBe("ab\nc");
});

test("history walks back and returns to the draft", () => {
  const editor = new Editor();
  editor.insert("one");
  expect(editor.take()).toBe("one");
  editor.insert("two");
  editor.take();
  editor.insert("draft");
  editor.previous();
  expect(editor.value).toBe("two");
  editor.previous();
  expect(editor.value).toBe("one");
  editor.next();
  editor.next();
  expect(editor.value).toBe("draft");
});

test("tools read as Kind(target)", () => {
  expect(toolLabel("execute", "`npm test`")).toBe("Run(npm test)");
  expect(toolLabel("read", "Read src/app.ts")).toBe("Read(src/app.ts)");
  expect(toolLabel("other", "fetch_page")).toBe("fetch_page");
});

test("a diff shows the changed lines with a line around them, numbered", () => {
  const diff = diffRows("a\nb\nc\nd\ne\nf\n", "a\nb\nC\nd\ne\nf\n");
  expect(diff.rows).toEqual(["2   b", "3 - c", "3 + C", "4   d", "  ┆"]);
  expect(diff).toMatchObject({ added: 1, removed: 1 });
  expect(diffRows("", "new\nfile\n")).toMatchObject({ rows: ["1 + new", "2 + file"], added: 2 });
});

test("↑ also brings back what was sent from elsewhere, once each", () => {
  const editor = new Editor();
  editor.remember("from the phone");
  editor.insert("typed here");
  editor.take();
  // The session echoes what this terminal sent: not twice.
  editor.remember("typed here");
  editor.previous();
  expect(editor.value).toBe("typed here");
  // A message arriving while ↑ is in use leaves the shown one in place.
  editor.remember("later, from the phone");
  editor.previous();
  expect(editor.value).toBe("from the phone");
  editor.next();
  editor.next();
  expect(editor.value).toBe("later, from the phone");
});
