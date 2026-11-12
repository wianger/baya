import { describe, expect, test } from "vitest";
import {
  BAYA_RUN_KEY,
  BAYA_RUN_VALUE,
  buildWindowsLauncher,
  buildWindowsStartupCommand,
  windowsArgument,
} from "../src/service.ts";

describe("per-user Windows startup", () => {
  test("uses the current-user Run key", () => {
    expect(BAYA_RUN_KEY).toBe("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run");
    expect(BAYA_RUN_VALUE).toBe("BayaHost");
  });

  test("the Run key starts wscript, which never opens a console", () => {
    const command = buildWindowsStartupCommand({
      launcher: "C:\\Users\\O'Brien\\.baya\\runtime\\autostart.js",
      systemRoot: "C:\\Windows",
    });
    expect(command).toBe(
      '"C:\\Windows\\System32\\wscript.exe" //B //Nologo //E:JScript "C:\\Users\\O\'Brien\\.baya\\runtime\\autostart.js"',
    );
  });

  test("the launcher starts the host hidden, its arguments quoted for CreateProcess", () => {
    const script = buildWindowsLauncher({
      command: ["C:\\Program Files\\node.exe", "C:\\Users\\O'Brien\\baya\\dist\\cli.js"],
      cwd: "C:\\Users\\O'Brien\\project space\\",
      logDir: "C:\\Users\\O'Brien\\.baya\\logs",
    });
    expect(script).toContain(
      'shell.CurrentDirectory = "C:\\\\Users\\\\O\'Brien\\\\project space\\\\";',
    );
    const run = /shell\.Run\((".*"), 0, false\);/u.exec(script)!;
    expect(JSON.parse(run[1]!)).toBe(
      '"C:\\Program Files\\node.exe" C:\\Users\\O\'Brien\\baya\\dist\\cli.js serve --cwd ' +
        "\"C:\\Users\\O'Brien\\project space\\\\\" --log C:\\Users\\O'Brien\\.baya\\logs\\host.log",
    );
  });

  test("arguments round-trip through Windows command-line parsing", () => {
    expect(windowsArgument("plain")).toBe("plain");
    expect(windowsArgument("")).toBe('""');
    expect(windowsArgument('say "hi"')).toBe('"say \\"hi\\""');
    expect(windowsArgument('a\\"b')).toBe('"a\\\\\\"b"');
    expect(windowsArgument("dir with space\\")).toBe('"dir with space\\\\"');
  });
});

const target = {
  command: ["/usr/bin/node", "/home/a b/baya/dist/cli.js"],
  cwd: '/home/a b/100% "done"',
  path: "/usr/local/bin:/usr/bin",
  logDir: "/home/a b/.baya/logs",
  launcher: "/home/a b/.baya/runtime/autostart.js",
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
