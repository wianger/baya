import { describe, expect, test } from "vitest";
import {
  BAYA_RUN_KEY,
  BAYA_RUN_VALUE,
  buildWindowsStartupCommand,
} from "../src/service.js";

describe("per-user Windows startup", () => {
  test("uses the current-user Run key", () => {
    expect(BAYA_RUN_KEY).toBe(
      "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
    );
    expect(BAYA_RUN_VALUE).toBe("BayaHost");
  });

  test("builds a hidden command that preserves spaces and apostrophes", () => {
    const command = buildWindowsStartupCommand({
      nodePath: "C:\\Program Files\\node.exe",
      entryPath: "C:\\Users\\O'Brien\\baya\\dist\\cli.js",
      cwd: "C:\\Users\\O'Brien\\project space",
      systemRoot: "C:\\Windows",
    });

    expect(command).toContain(
      '"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"',
    );
    expect(command).toContain("-WindowStyle Hidden");
    expect(command).toContain("-EncodedCommand ");

    const encoded = command.split("-EncodedCommand ")[1]!;
    const script = Buffer.from(encoded, "base64").toString("utf16le");
    expect(script).toContain("'C:\\Program Files\\node.exe'");
    expect(script).toContain(
      "'C:\\Users\\O''Brien\\baya\\dist\\cli.js'",
    );
    expect(script).toContain(
      "'C:\\Users\\O''Brien\\project space'",
    );
  });
});
