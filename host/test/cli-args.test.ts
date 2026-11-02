import { describe, expect, test } from "vitest";
import { parseArgs } from "../src/cli/args.ts";

describe("CLI argument parsing", () => {
  test("defaults a commandless invocation to serve", () => {
    expect(parseArgs([])).toEqual({
      command: "serve",
      positionals: [],
      flags: new Map(),
    });
    expect(parseArgs(["--cwd", "C:\\work"]).command).toBe("serve");
  });

  test("keeps explicit help from accidentally starting the host", () => {
    expect(parseArgs(["help"])).toEqual({
      command: "help",
      positionals: [],
      flags: new Map(),
    });
    expect(parseArgs(["--help"]).command).toBe("help");
    expect(parseArgs(["start", "--help"]).command).toBe("help");
    expect(parseArgs(["new", "-h"]).command).toBe("help");
  });

  test("parses inline and separated flags without consuming the subcommand path", () => {
    expect(parseArgs(["new", "--agent=codex", "C:\\work", "--name", "Review", "--json"])).toEqual({
      command: "new",
      positionals: ["C:\\work"],
      flags: new Map<string, string | boolean>([
        ["agent", "codex"],
        ["name", "Review"],
        ["json", true],
      ]),
    });
  });
});
