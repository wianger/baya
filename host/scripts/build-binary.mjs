// Builds the single-file `baya` executable for this platform with Node's
// single executable applications: bundle, then `node --build-sea` (Node 26),
// which embeds and injects in one step, with V8's code cache for a faster
// start (each platform builds its own binary, so the cache matches).
//
//   pnpm build:binary        → build/bin/baya-<platform>-<arch>[.exe]
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "build", "sea");
const { version } = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
const target = `${process.platform}-${process.arch}`;
const exe = join(root, "build", "bin", `baya-${target}${process.platform === "win32" ? ".exe" : ""}`);

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
mkdirSync(dirname(exe), { recursive: true });

// 1. One CommonJS file; the keyring addon comes from the embedded asset.
const shim = join(root, "scripts", "keyring-sea.cjs");
await build({
  entryPoints: [join(root, "src", "cli.ts")],
  outfile: join(out, "baya.cjs"),
  bundle: true,
  platform: "node",
  format: "cjs",
  target: "node24",
  define: { __BAYA_VERSION__: JSON.stringify(version) },
  external: ["bufferutil", "utf-8-validate"],
  logLevel: "warning",
  plugins: [
    {
      name: "keyring-asset",
      setup(b) {
        b.onResolve({ filter: /^@napi-rs\/keyring$/ }, () => ({ path: shim }));
      },
    },
  ],
});

// 2. This platform's keyring addon.
const keyringRequire = createRequire(createRequire(import.meta.url).resolve("@napi-rs/keyring"));
const triple = {
  "linux-x64": "linux-x64-gnu",
  "linux-arm64": "linux-arm64-gnu",
  "darwin-x64": "darwin-x64",
  "darwin-arm64": "darwin-arm64",
  "win32-x64": "win32-x64-msvc",
  "win32-arm64": "win32-arm64-msvc",
}[target];
if (!triple) throw new Error(`No keyring build for ${target}.`);
const addonDir = dirname(keyringRequire.resolve(`@napi-rs/keyring-${triple}/package.json`));
const addon = join(addonDir, readdirSync(addonDir).find((name) => name.endsWith(".node")));

// 3. The executable: this Node, the bundle and the assets, in one step.
const [major] = process.versions.node.split(".").map(Number);
if (major < 26) throw new Error(`Building the binary needs Node 26 or newer (this is ${process.version}).`);
const config = join(out, "sea-config.json");
writeFileSync(
  config,
  JSON.stringify({
    main: join(out, "baya.cjs"),
    output: exe,
    disableExperimentalSEAWarning: true,
    useCodeCache: true,
    useSnapshot: false,
    assets: { "keyring.node": addon },
  }),
);
execFileSync(process.execPath, ["--build-sea", config], { stdio: "inherit" });
if (process.platform === "darwin") execFileSync("codesign", ["--force", "--sign", "-", exe]);
console.log(exe);
