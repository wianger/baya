// Stands in for @napi-rs/keyring inside the single executable: the native
// addon travels as an embedded asset and is loaded from a cached copy.
const { existsSync, mkdirSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const sea = require("node:sea");

const asset = Buffer.from(sea.getRawAsset("keyring.node"));
const dir = join(tmpdir(), "baya");
const file = join(dir, `keyring-${__BAYA_VERSION__}-${process.platform}-${process.arch}.node`);
if (!existsSync(file)) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(file, asset);
}
const loaded = { exports: {} };
process.dlopen(loaded, file);
module.exports = loaded.exports;
