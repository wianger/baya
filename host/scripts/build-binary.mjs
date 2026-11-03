// Builds the single-file `baya` executable for this platform with Node's
// single executable applications: bundle, embed, inject.
//
//   pnpm build:binary        → build/bin/baya-<platform>-<arch>[.exe]
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { inject } from "postject";

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

// 3. The blob Node runs at startup.
const config = join(out, "sea-config.json");
writeFileSync(
  config,
  JSON.stringify({
    main: join(out, "baya.cjs"),
    output: join(out, "sea-prep.blob"),
    disableExperimentalSEAWarning: true,
    useCodeCache: false,
    useSnapshot: false,
    assets: { "keyring.node": addon },
  }),
);
execFileSync(process.execPath, ["--experimental-sea-config", config], { stdio: "inherit" });

// 4. A copy of this Node with the blob injected.
copyFileSync(process.execPath, exe);
if (process.platform === "darwin") execFileSync("codesign", ["--remove-signature", exe]);
await inject(exe, "NODE_SEA_BLOB", readFileSync(join(out, "sea-prep.blob")), {
  sentinelFuse: "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2",
  ...(process.platform === "darwin" ? { machoSegmentName: "NODE_SEA" } : {}),
});
if (process.platform === "darwin") execFileSync("codesign", ["--sign", "-", exe]);
console.log(exe);
