import { describe, expect, test } from "vitest";
import { BAYA_RUN_KEY, BAYA_RUN_VALUE, buildWindowsStartupCommand } from "../src/service.ts";

describe("per-user Windows startup", () => {
  test("uses the current-user Run key", () => {
    expect(BAYA_RUN_KEY).toBe("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run");
    expect(BAYA_RUN_VALUE).toBe("BayaHost");
  });

  test("builds a hidden command that preserves spaces and apostrophes", () => {
    const command = buildWindowsStartupCommand({
      nodePath: "C:\\Program Files\\node.exe",
      entryPath: "C:\\Users\\O'Brien\\baya\\dist\\cli.js",
      cwd: "C:\\Users\\O'Brien\\project space",
      systemRoot: "C:\\Windows",
    });

    expect(command).toContain('"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"');
    expect(command).toContain("-WindowStyle Hidden");
    expect(command).toContain("-EncodedCommand ");

    const encoded = command.split("-EncodedCommand ")[1]!;
    const script = Buffer.from(encoded, "base64").toString("utf16le");
    expect(script).toContain("'C:\\Program Files\\node.exe'");
    expect(script).toContain("'C:\\Users\\O''Brien\\baya\\dist\\cli.js'");
    expect(script).toContain("'C:\\Users\\O''Brien\\project space'");
  });
});

const target = {
  nodePath: "/usr/bin/node",
  entryPath: "/home/a b/baya/dist/cli.js",
  cwd: '/home/a b/100% "done"',
  path: "/usr/local/bin:/usr/bin",
  logDir: "/home/a b/.baya/logs",
};

describe("systemd and launchd startup", () => {
  test("systemd unit quotes paths and escapes specifiers", async () => {
    const { buildSystemdUnit } = await import("../src/service.js");
    const unit = buildSystemdUnit(target);
    expect(unit).toContain(
      'ExecStart="/usr/bin/node" "/home/a b/baya/dist/cli.js" "serve" "--cwd" "/home/a b/100%% \\"done\\""',
    );
    expect(unit).toContain('Environment="PATH=/usr/local/bin:/usr/bin"');
    expect(unit).toContain("Restart=on-failure");
  });

  test("LaunchAgent plist escapes XML", async () => {
    const { buildLaunchAgentPlist } = await import("../src/service.js");
    const plist = buildLaunchAgentPlist({ ...target, cwd: "/Users/a&b/<repo>" });
    expect(plist).toContain("<string>/Users/a&amp;b/&lt;repo&gt;</string>");
    expect(plist).toContain("<key>RunAtLoad</key>");
  });
});
