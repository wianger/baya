import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { deflateRawSync, gzipSync } from "node:zlib";
import { afterEach, expect, test } from "vitest";
import { extractEntry, listArchive } from "../src/workspace/file_views.ts";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function folder(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "baya-views-")));
  dirs.push(dir);
  return dir;
}

/** A zip with one stored and one deflated entry, as zip tools write them. */
function zip(files: Array<{ name: string; data: string; deflate: boolean }>): Buffer {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const file of files) {
    const name = Buffer.from(file.name);
    const raw = Buffer.from(file.data);
    const body = file.deflate ? deflateRawSync(raw) : raw;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(file.deflate ? 8 : 0, 8);
    local.writeUInt32LE(body.length, 18);
    local.writeUInt32LE(raw.length, 22);
    local.writeUInt16LE(name.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(0x800, 8);
    central.writeUInt16LE(file.deflate ? 8 : 0, 10);
    central.writeUInt32LE(body.length, 20);
    central.writeUInt32LE(raw.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(offset, 42);
    locals.push(local, name, body);
    centrals.push(central, name);
    offset += 30 + name.length + body.length;
  }
  const cd = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}

function tar(files: Array<{ name: string; data: string }>): Buffer {
  const parts: Buffer[] = [];
  for (const file of files) {
    const header = Buffer.alloc(512);
    header.write(file.name, 0);
    header.write(`${file.data.length.toString(8).padStart(11, "0")}\0`, 124);
    header.write("0", 156);
    parts.push(header);
    const body = Buffer.alloc(Math.ceil(file.data.length / 512) * 512);
    body.write(file.data);
    parts.push(body);
  }
  parts.push(Buffer.alloc(1024));
  return Buffer.concat(parts);
}

test("a zip lists its entries and gives one up", async () => {
  const root = folder();
  const archive = join(root, "bundle.zip");
  writeFileSync(
    archive,
    zip([
      { name: "README.md", data: "# hi", deflate: false },
      { name: "src/main.ts", data: "console.log(1);\n".repeat(50), deflate: true },
      { name: "../../escape.txt", data: "no", deflate: false },
    ]),
  );
  const listed = await listArchive(root, archive);
  expect(listed.entries.map((e) => [e.name, e.size])).toEqual([
    ["README.md", 4],
    ["src/main.ts", 800],
    ["../../escape.txt", 2],
  ]);
  const main = await extractEntry(root, archive, "src/main.ts");
  expect(main.path.startsWith(join(root, ".baya", "extracted"))).toBe(true);
  expect(readFileSync(main.path, "utf8")).toBe("console.log(1);\n".repeat(50));
  // An entry naming a way out lands inside all the same.
  const outward = await extractEntry(root, archive, "../../escape.txt");
  expect(outward.path.startsWith(join(root, ".baya", "extracted"))).toBe(true);
  expect(readFileSync(join(root, ".baya", ".gitignore"), "utf8")).toBe("*\n");
});

test("a tar.gz lists and extracts", async () => {
  const root = folder();
  const archive = join(root, "logs.tar.gz");
  writeFileSync(archive, gzipSync(tar([{ name: "logs/app.log", data: "started\n" }])));
  expect((await listArchive(root, archive)).entries).toEqual([
    { name: "logs/app.log", size: 8, directory: false },
  ]);
  const log = await extractEntry(root, archive, "logs/app.log");
  expect(readFileSync(log.path, "utf8")).toBe("started\n");
});

test("archives outside the session and other files are refused", async () => {
  const root = folder();
  const elsewhere = join(folder(), "x.zip");
  writeFileSync(elsewhere, zip([{ name: "a", data: "a", deflate: false }]));
  await expect(listArchive(root, elsewhere)).rejects.toThrow(/outside/);
  writeFileSync(join(root, "notes.txt"), "hi");
  await expect(listArchive(root, join(root, "notes.txt"))).rejects.toThrow(/not an archive/);
});
