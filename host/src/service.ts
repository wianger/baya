import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, win32 } from "node:path";

/**
 * Per-user login startup for the resident host. No platform needs admin
 * rights: Windows uses the HKCU Run key, Linux a systemd user unit, and macOS
 * a LaunchAgent. systemd and launchd also restart the host if it crashes.
 */
interface StartupTarget {
  /** Runs Baya: the executable, or Node and the script. */
  command: string[];
  cwd: string;
  /** PATH for the service, so it finds the agents' commands. */
  path: string;
  logDir: string;
}

export const BAYA_RUN_KEY = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
export const BAYA_RUN_VALUE = "BayaHost";
const SYSTEMD_UNIT = "baya.service";
const LAUNCHD_LABEL = "dev.baya.host";

export function installStartup(target: StartupTarget): string {
  switch (process.platform) {
    case "win32":
      run("reg.exe", [
        "ADD",
        BAYA_RUN_KEY,
        "/V",
        BAYA_RUN_VALUE,
        "/T",
        "REG_SZ",
        "/D",
        buildWindowsStartupCommand({
          ...target,
          systemRoot: process.env["SystemRoot"] || "C:\\Windows",
        }),
        "/F",
      ]);
      return "Installed the per-user BayaHost Windows startup entry.";
    case "linux": {
      const unit = systemdUnitPath();
      mkdirSync(dirname(unit), { recursive: true });
      writeFileSync(unit, buildSystemdUnit(target));
      run("systemctl", ["--user", "daemon-reload"]);
      run("systemctl", ["--user", "enable", "--now", SYSTEMD_UNIT]);
      return (
        `Installed and started ${SYSTEMD_UNIT} (systemd user unit). ` +
        "Run `loginctl enable-linger` to keep it running while logged out."
      );
    }
    case "darwin": {
      const plist = launchAgentPath();
      mkdirSync(dirname(plist), { recursive: true });
      mkdirSync(target.logDir, { recursive: true });
      spawnSync("launchctl", ["bootout", launchdDomain(), plist]);
      writeFileSync(plist, buildLaunchAgentPlist(target));
      run("launchctl", ["bootstrap", launchdDomain(), plist]);
      return `Installed and started the ${LAUNCHD_LABEL} LaunchAgent.`;
    }
    default:
      throw new Error(`Login startup is not supported on ${process.platform}.`);
  }
}

export function uninstallStartup(): string {
  switch (process.platform) {
    case "win32": {
      const query = spawnSync("reg.exe", ["QUERY", BAYA_RUN_KEY, "/V", BAYA_RUN_VALUE], {
        windowsHide: true,
      });
      if (query.status !== 0) return "The BayaHost Windows startup entry is not installed.";
      run("reg.exe", ["DELETE", BAYA_RUN_KEY, "/V", BAYA_RUN_VALUE, "/F"]);
      return "Removed the BayaHost Windows startup entry.";
    }
    case "linux": {
      const unit = systemdUnitPath();
      if (!existsSync(unit)) return `${SYSTEMD_UNIT} is not installed.`;
      spawnSync("systemctl", ["--user", "disable", "--now", SYSTEMD_UNIT]);
      rmSync(unit);
      run("systemctl", ["--user", "daemon-reload"]);
      return `Removed ${SYSTEMD_UNIT}.`;
    }
    case "darwin": {
      const plist = launchAgentPath();
      if (!existsSync(plist)) return `The ${LAUNCHD_LABEL} LaunchAgent is not installed.`;
      spawnSync("launchctl", ["bootout", launchdDomain(), plist]);
      rmSync(plist);
      return `Removed the ${LAUNCHD_LABEL} LaunchAgent.`;
    }
    default:
      throw new Error(`Login startup is not supported on ${process.platform}.`);
  }
}

export function buildWindowsStartupCommand(input: {
  command: string[];
  cwd: string;
  systemRoot: string;
}): string {
  const [executable, ...prefix] = input.command;
  const script = [
    `& ${powerShellLiteral(executable!)}`,
    ...prefix.map(powerShellLiteral),
    "serve",
    "--cwd",
    powerShellLiteral(input.cwd),
  ].join(" ");
  const encoded = Buffer.from(script, "utf16le").toString("base64");
  const powershell = win32.join(
    input.systemRoot,
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe",
  );
  return `"${powershell}" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ${encoded}`;
}

export function buildSystemdUnit(target: StartupTarget): string {
  const exec = [...target.command, "serve", "--cwd", target.cwd].map(systemdQuote).join(" ");
  return `[Unit]
Description=Baya host
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${exec}
WorkingDirectory=${systemdQuote(target.cwd)}
Environment=${systemdQuote(`PATH=${target.path}`)}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
`;
}

export function buildLaunchAgentPlist(target: StartupTarget): string {
  const args = [...target.command, "serve", "--cwd", target.cwd]
    .map((arg) => `    <string>${xml(arg)}</string>`)
    .join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${args}
  </array>
  <key>WorkingDirectory</key>
  <string>${xml(target.cwd)}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${xml(target.path)}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardErrorPath</key>
  <string>${xml(join(target.logDir, "host.log"))}</string>
</dict>
</plist>
`;
}

function systemdUnitPath(): string {
  const config = process.env["XDG_CONFIG_HOME"] || join(homedir(), ".config");
  return join(config, "systemd", "user", SYSTEMD_UNIT);
}

function launchAgentPath(): string {
  return join(homedir(), "Library", "LaunchAgents", `${LAUNCHD_LABEL}.plist`);
}

function launchdDomain(): string {
  return `gui/${process.getuid?.() ?? 0}`;
}

function run(command: string, args: string[]): void {
  const result = spawnSync(command, args, { encoding: "utf8", windowsHide: true });
  if (result.error) throw new Error(`Could not run ${command}: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || `${command} failed.`).trim());
  }
}

function powerShellLiteral(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

/** systemd double-quoted word; `%` is a specifier and must be doubled. */
function systemdQuote(value: string): string {
  return `"${value.replace(/[\\"]/g, "\\$&").replace(/%/g, "%%")}"`;
}

function xml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
