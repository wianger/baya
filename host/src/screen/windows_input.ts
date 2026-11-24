/**
 * Mouse and keyboard on Windows, from a phone: one PowerShell process that
 * compiles a few lines of C# over `SendInput` and reads short commands on
 * stdin, one per line. It starts once per remote-control session and stays
 * up, so a move costs a line written to a pipe.
 *
 * Commands (coordinates in physical pixels of the virtual desktop):
 *   m x y        move to
 *   r dx dy      move by
 *   b l|r|m 1|0  button down/up
 *   w dy dx      wheel (120 is one notch)
 *   k vk 1|0 e   key down/up; e=1 for extended keys (arrows, Home, Del…)
 *   t base64     type text (UTF-8, base64)
 * The first line it writes is the screens, as JSON.
 */
import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createInterface } from "node:readline";

const SOURCE = `
using System;
using System.Runtime.InteropServices;
public static class BayaInput {
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  const uint MOVE = 0x1, LDOWN = 0x2, LUP = 0x4, RDOWN = 0x8, RUP = 0x10, MDOWN = 0x20, MUP = 0x40;
  const uint WHEEL = 0x800, HWHEEL = 0x1000, ABSOLUTE = 0x8000, VIRTUALDESK = 0x4000;
  const uint KEYUP = 0x2, UNICODE = 0x4, EXTENDED = 0x1;
  static void Send(INPUT input) { SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))); }
  static INPUT Mouse(int dx, int dy, uint data, uint flags) {
    var i = new INPUT { type = 0 }; i.u.mi = new MOUSEINPUT { dx = dx, dy = dy, mouseData = data, dwFlags = flags }; return i;
  }
  static INPUT Key(ushort vk, ushort scan, uint flags) {
    var i = new INPUT { type = 1 }; i.u.ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags }; return i;
  }
  public static void MoveTo(int x, int y) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    int nx = (int)Math.Round((x - vx) * 65535.0 / Math.Max(1, vw - 1));
    int ny = (int)Math.Round((y - vy) * 65535.0 / Math.Max(1, vh - 1));
    Send(Mouse(nx, ny, 0, MOVE | ABSOLUTE | VIRTUALDESK));
  }
  public static void MoveBy(int dx, int dy) { POINT p; GetCursorPos(out p); MoveTo(p.X + dx, p.Y + dy); }
  public static void Button(string b, bool down) {
    uint f = b == "r" ? (down ? RDOWN : RUP) : b == "m" ? (down ? MDOWN : MUP) : (down ? LDOWN : LUP);
    Send(Mouse(0, 0, 0, f));
  }
  public static void Wheel(int dy, int dx) {
    if (dy != 0) Send(Mouse(0, 0, unchecked((uint)dy), WHEEL));
    if (dx != 0) Send(Mouse(0, 0, unchecked((uint)dx), HWHEEL));
  }
  public static void KeyVk(ushort vk, bool down, bool extended) {
    Send(Key(vk, 0, (down ? 0 : KEYUP) | (extended ? EXTENDED : 0)));
  }
  public static void Text(string s) {
    foreach (char c in s) { Send(Key(0, c, UNICODE)); Send(Key(0, c, UNICODE | KEYUP)); }
  }
}`;

const LOOP = `
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition $env:BAYA_INPUT_SOURCE
[void][BayaInput]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms
$screens = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
  @{ x = $_.Bounds.X; y = $_.Bounds.Y; width = $_.Bounds.Width; height = $_.Bounds.Height; primary = $_.Primary }
})
[Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject $screens))
[Console]::Out.Flush()
while ($null -ne ($line = [Console]::In.ReadLine())) {
  $p = $line.Split(' ')
  try {
    switch ($p[0]) {
      'm' { [BayaInput]::MoveTo([int]$p[1], [int]$p[2]) }
      'r' { [BayaInput]::MoveBy([int]$p[1], [int]$p[2]) }
      'b' { [BayaInput]::Button($p[1], $p[2] -eq '1') }
      'w' { [BayaInput]::Wheel([int]$p[1], [int]$p[2]) }
      'k' { [BayaInput]::KeyVk([uint16]$p[1], $p[2] -eq '1', $p[3] -eq '1') }
      't' { [BayaInput]::Text([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p[1]))) }
    }
  } catch { }
}
`;

export interface Screen {
  x: number;
  y: number;
  width: number;
  height: number;
  primary: boolean;
}

/** Virtual-key codes by the names phones send. */
export const VIRTUAL_KEYS: Record<string, { vk: number; extended?: boolean }> = {
  backspace: { vk: 0x08 },
  tab: { vk: 0x09 },
  enter: { vk: 0x0d },
  shift: { vk: 0x10 },
  ctrl: { vk: 0x11 },
  alt: { vk: 0x12 },
  escape: { vk: 0x1b },
  space: { vk: 0x20 },
  pageup: { vk: 0x21, extended: true },
  pagedown: { vk: 0x22, extended: true },
  end: { vk: 0x23, extended: true },
  home: { vk: 0x24, extended: true },
  left: { vk: 0x25, extended: true },
  up: { vk: 0x26, extended: true },
  right: { vk: 0x27, extended: true },
  down: { vk: 0x28, extended: true },
  delete: { vk: 0x2e, extended: true },
  win: { vk: 0x5b, extended: true },
  ...Object.fromEntries(Array.from({ length: 12 }, (_, i) => [`f${i + 1}`, { vk: 0x70 + i }])),
  ...Object.fromEntries(
    Array.from({ length: 26 }, (_, i) => [String.fromCharCode(97 + i), { vk: 0x41 + i }]),
  ),
  ...Object.fromEntries(Array.from({ length: 10 }, (_, i) => [String(i), { vk: 0x30 + i }])),
};

/** One running helper. */
export class WindowsInput {
  private readonly child: ChildProcessWithoutNullStreams;
  readonly screens: Promise<Screen[]>;

  constructor() {
    this.child = spawn(
      "powershell.exe",
      [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        Buffer.from(LOOP, "utf16le").toString("base64"),
      ],
      {
        windowsHide: true,
        env: { ...process.env, BAYA_INPUT_SOURCE: SOURCE },
      },
    );
    this.child.stdin.on("error", () => {});
    const lines = createInterface({ input: this.child.stdout });
    this.screens = new Promise((resolve, reject) => {
      lines.once("line", (line) => {
        try {
          const parsed = JSON.parse(line) as Screen | Screen[];
          resolve(Array.isArray(parsed) ? parsed : [parsed]);
        } catch (error) {
          reject(error as Error);
        }
      });
      this.child.once("exit", () => reject(new Error("The input helper ended.")));
    });
    this.screens.catch(() => {});
  }

  send(line: string): void {
    if (this.child.stdin.writable) this.child.stdin.write(`${line}\n`);
  }

  close(): void {
    this.child.stdin.end();
    setTimeout(() => this.child.kill(), 1000).unref();
  }
}
