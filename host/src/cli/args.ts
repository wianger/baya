export interface ParsedArgs {
  command: string;
  positionals: string[];
  flags: Map<string, string | true>;
}

export function parseArgs(argv: string[]): ParsedArgs {
  if (argv[0] === "help" || argv.includes("--help") || argv.includes("-h")) {
    return {
      command: "help",
      positionals: [],
      flags: new Map(),
    };
  }
  const first = argv[0];
  const standalone = first === "--version" || first === "-v";
  const command = standalone ? first : first && !first.startsWith("-") ? first : "serve";
  const rest = first === command || standalone ? argv.slice(1) : argv;
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
  return { command, positionals, flags };
}

export function stringFlag(args: ParsedArgs, name: string): string | undefined {
  const value = args.flags.get(name);
  return typeof value === "string" ? value : undefined;
}

export function booleanFlag(args: ParsedArgs, name: string): boolean {
  return args.flags.get(name) === true;
}
