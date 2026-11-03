export interface ParsedArgs {
  command: string;
  positionals: string[];
  flags: Map<string, string | true>;
  /** Everything after `--`, verbatim: an agent's command line. */
  passthrough: string[];
}

export function parseArgs(input: string[]): ParsedArgs {
  const separator = input.indexOf("--");
  const argv = separator >= 0 ? input.slice(0, separator) : input;
  const passthrough = separator >= 0 ? input.slice(separator + 1) : [];
  if (argv[0] === "help" || argv.includes("--help") || argv.includes("-h")) {
    return { command: "help", positionals: [], flags: new Map(), passthrough };
  }
  const first = argv[0];
  if (first === "--version" || first === "-v") {
    return { command: "version", positionals: [], flags: new Map(), passthrough };
  }
  // No command: `baya` starts (or shows) the host — the one thing to remember.
  const command = first && !first.startsWith("-") ? first : "up";
  const rest = first === command ? argv.slice(1) : argv;
  const positionals: string[] = [];
  const flags = new Map<string, string | true>();
  for (let index = 0; index < rest.length; index++) {
    const item = rest[index]!;
    if (!item.startsWith("--")) {
      positionals.push(item);
      continue;
    }
    const separator = item.indexOf("=");
    const rawKey = separator >= 0 ? item.slice(2, separator) : item.slice(2);
    const inline = separator >= 0 ? item.slice(separator + 1) : undefined;
    if (!rawKey) continue;
    if (inline !== undefined) {
      flags.set(rawKey, inline);
      continue;
    }
    const next = rest[index + 1];
    if (next && !next.startsWith("--")) {
      flags.set(rawKey, next);
      index++;
    } else {
      flags.set(rawKey, true);
    }
  }
  return { command, positionals, flags, passthrough };
}

export function stringFlag(args: ParsedArgs, name: string): string | undefined {
  const value = args.flags.get(name);
  return typeof value === "string" ? value : undefined;
}

export function booleanFlag(args: ParsedArgs, name: string): boolean {
  return args.flags.get(name) === true;
}
