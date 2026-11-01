import { win32 } from "node:path";

export const BAYA_RUN_KEY =
  "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
export const BAYA_RUN_VALUE = "BayaHost";

function powerShellLiteral(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

export function buildWindowsStartupCommand(input: {
  nodePath: string;
  entryPath: string;
  cwd: string;
  systemRoot: string;
}): string {
  const script = [
    `& ${powerShellLiteral(input.nodePath)}`,
    powerShellLiteral(input.entryPath),
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
