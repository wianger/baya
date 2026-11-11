/**
 * `baya update`: replaces the single-file executable with the newest
 * `host-v<version>` release, after checking it against the release's
 * SHA256SUMS. A Baya run from source is updated with git instead.
 */
import { createHash } from "node:crypto";
import { chmodSync, existsSync, renameSync, rmSync, writeFileSync } from "node:fs";

const RELEASES = "https://api.github.com/repos/wianger/baya/releases?per_page=50";

interface HostRelease {
  version: string;
  assets: Map<string, string>;
}

/** The executable's name in a release, for this or another platform. */
export function assetName(platform = process.platform, arch = process.arch): string {
  return `baya-${platform}-${arch}${platform === "win32" ? ".exe" : ""}`;
}

/** Negative, zero or positive, as for sorting: compares x.y.z versions. */
export function compareVersions(a: string, b: string): number {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

/** The newest published host release in a GitHub releases listing. */
export function newestRelease(listing: unknown): HostRelease | null {
  if (!Array.isArray(listing)) return null;
  let best: HostRelease | null = null;
  for (const release of listing) {
    if (release?.draft !== false) continue;
    const match = /^host-v(\d+\.\d+\.\d+)$/u.exec(String(release.tag_name ?? ""));
    if (!match) continue;
    const version = match[1]!;
    if (best && compareVersions(version, best.version) <= 0) continue;
    const assets = new Map<string, string>();
    for (const asset of Array.isArray(release.assets) ? release.assets : []) {
      if (typeof asset?.name === "string" && typeof asset?.browser_download_url === "string") {
        assets.set(asset.name, asset.browser_download_url);
      }
    }
    best = { version, assets };
  }
  return best;
}

/** The digest SHA256SUMS lists for [name], or null. */
export function expectedDigest(sums: string, name: string): string | null {
  for (const line of sums.split(/\r?\n/u)) {
    const [digest, file] = line.trim().split(/\s+\*?/u);
    if (file === name && digest && /^[0-9a-f]{64}$/u.test(digest)) return digest;
  }
  return null;
}

async function download(url: string): Promise<Buffer> {
  const response = await fetch(url, { headers: { "User-Agent": "baya-update" } });
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return Buffer.from(await response.arrayBuffer());
}

export async function latestHostRelease(): Promise<HostRelease | null> {
  const response = await fetch(RELEASES, {
    headers: { Accept: "application/vnd.github+json", "User-Agent": "baya-update" },
  });
  if (!response.ok) throw new Error(`GitHub releases: HTTP ${response.status}`);
  return newestRelease(await response.json());
}

/** Downloads [release]'s executable for this computer, checks and installs it. */
export async function installRelease(release: HostRelease, executable: string): Promise<void> {
  const name = assetName();
  const url = release.assets.get(name);
  const sumsUrl = release.assets.get("SHA256SUMS");
  if (!url || !sumsUrl) throw new Error(`Release ${release.version} has no ${name}.`);
  const [binary, sums] = await Promise.all([download(url), download(sumsUrl)]);
  const expected = expectedDigest(sums.toString("utf8"), name);
  const actual = createHash("sha256").update(binary).digest("hex");
  if (!expected || expected !== actual) {
    throw new Error(`${name} does not match its checksum; nothing was changed.`);
  }
  if (process.platform === "win32") {
    // A running .exe cannot be overwritten, but it can be moved aside.
    const old = `${executable}.old`;
    rmSync(old, { force: true });
    renameSync(executable, old);
    writeFileSync(executable, binary);
  } else {
    const next = `${executable}.new`;
    writeFileSync(next, binary);
    chmodSync(next, 0o755);
    renameSync(next, executable);
  }
}

/** Removes the copy a Windows update moved aside, once it is no longer running. */
export function cleanUpAfterUpdate(executable: string): void {
  const old = `${executable}.old`;
  if (existsSync(old)) rmSync(old, { force: true });
}
