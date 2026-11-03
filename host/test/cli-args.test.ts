import { describe, expect, test } from "vitest";
import { parseArgs } from "../src/cli/args.ts";

describe("CLI argument parsing", () => {
  test("defaults a commandless invocation to up", () => {
    expect(parseArgs([])).toEqual({
      command: "up",
      positionals: [],
      flags: new Map(),
      passthrough: [],
    });
    expect(parseArgs(["--cwd", "C:\\work"]).command).toBe("up");
  });

  test("keeps explicit help from accidentally starting the host", () => {
    expect(parseArgs(["help"])).toEqual({
      command: "help",
      positionals: [],
      flags: new Map(),
      passthrough: [],
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
      passthrough: [],
    });
  });

  test("keeps an agent command after -- verbatim, even its own --help", () => {
    expect(
      parseArgs(["agents", "add", "x", "--name", "X", "--", "npx", "-y", "a", "--help"]),
    ).toEqual({
      command: "agents",
      positionals: ["add", "x"],
      flags: new Map([["name", "X"]]),
      passthrough: ["npx", "-y", "a", "--help"],
    });
  });
});

describe("typo suggestions", () => {
  test("a swapped pair of letters is one edit", async () => {
    const { suggest } = await import("../src/cli/ui.ts");
    const commands = ["start", "status", "stop", "pair", "devices"];
    expect(suggest("stauts", commands)).toBe("status");
    expect(suggest("devcies", commands)).toBe("devices");
    expect(suggest("xyz", commands)).toBeUndefined();
  });
});

describe("agent environment", () => {
  test("leading NAME=value words are the agent's environment", async () => {
    const { splitEnv } = await import("../src/config.ts");
    expect(splitEnv(["CODEX_PATH=/usr/bin/codex", "A=b=c", "codex-acp", "X=1"])).toEqual({
      env: { CODEX_PATH: "/usr/bin/codex", A: "b=c" },
      command: ["codex-acp", "X=1"],
    });
  });
});
