import { existsSync, statSync } from "node:fs";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { BAYA_HOME } from "../config.ts";
import {
  canonicalizeEd25519PublicKey,
  type Ed25519Keypair,
  generateEd25519Keypair,
} from "./crypto.ts";

/**
 * Host identity and paired-device storage.
 *
 * The long-term Ed25519 identity lives in the OS keyring (Keychain, Windows
 * Credential Manager, libsecret). A file at `$BAYA_HOME/identity.json` (0600)
 * is used when the keyring is unavailable, and once such a file exists it
 * always wins: the phone paired against that key, so a keyring that comes
 * online later must never mask it.
 */

const SERVICE = "dev.wianger.baya";
const ACCOUNT = "longterm-ed25519";
const KEYRING_TIMEOUT_MS = 3_000;
const KEYRING_ATTEMPTS = 3;

const IDENTITY_FILE = join(BAYA_HOME, "identity.json");
const PEERS_FILE = join(BAYA_HOME, "peers.json");

/** The keyring is a core OS service but stayed unreadable (usually locked). */
export class KeyringUnavailableError extends Error {
  override readonly name = "KeyringUnavailableError";
  constructor(cause: unknown) {
    super(
      "The OS keyring is unreadable and no file identity exists. Baya will not " +
        "create a new identity because that would break existing pairings. " +
        "Unlock the keyring and retry, or set BAYA_ALLOW_FILE_IDENTITY=1.",
      { cause },
    );
  }
}

/** Devices are paired, so a missing identity is an environment problem. */
export class PairedIdentityMissingError extends Error {
  override readonly name = "PairedIdentityMissingError";
  constructor(paired: number, cause: unknown) {
    super(
      `No identity could be read, but ${paired} device(s) are paired. Baya will ` +
        "not create a new identity because that would disconnect them. Give this " +
        `process keyring access, or pin the paired key in ${IDENTITY_FILE} (0600).`,
      { cause },
    );
  }
}

// ── Keyring ──────────────────────────────────────────────────────────────────

type AsyncEntryCtor = typeof import("@napi-rs/keyring").AsyncEntry;
let keyringModule: Promise<AsyncEntryCtor> | null = null;
let keyringMissing = false;

/** Loaded lazily so a missing native binding degrades to the file store. */
function loadKeyring(): Promise<AsyncEntryCtor> {
  keyringModule ??= import("@napi-rs/keyring").then(
    (module) => module.AsyncEntry,
    (error: unknown) => {
      keyringMissing = true;
      throw error;
    },
  );
  return keyringModule;
}

/** Native calls can block forever on a prompt nobody can see; bound them. */
function withTimeout<T>(promise: Promise<T>, operation: string): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`keyring ${operation} timed out`)),
      KEYRING_TIMEOUT_MS,
    );
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function keyringRead(service: string): Promise<string | undefined> {
  const AsyncEntry = await loadKeyring();
  return withTimeout(new AsyncEntry(service, ACCOUNT).getPassword(), "read");
}

async function keyringWrite(service: string, value: string): Promise<void> {
  const AsyncEntry = await loadKeyring();
  await withTimeout(new AsyncEntry(service, ACCOUNT).setPassword(value), "write");
}

// ── Identity ─────────────────────────────────────────────────────────────────

function serialize(keypair: Ed25519Keypair): string {
  return JSON.stringify({
    pk: Buffer.from(keypair.publicKey).toString("base64"),
    sk: Buffer.from(keypair.secretKey).toString("base64"),
  });
}

function deserialize(stored: string): Ed25519Keypair {
  const parsed = JSON.parse(stored) as { pk: string; sk: string };
  return {
    publicKey: Buffer.from(parsed.pk, "base64"),
    secretKey: Buffer.from(parsed.sk, "base64"),
  };
}

async function readIdentityFile(path: string): Promise<Ed25519Keypair | null> {
  try {
    return deserialize(await readFile(path, "utf8"));
  } catch {
    return null;
  }
}

async function writePrivate(path: string, contents: string): Promise<void> {
  await mkdir(BAYA_HOME, { recursive: true, mode: 0o700 });
  await writeFile(path, contents, { mode: 0o600 });
  await chmod(path, 0o600).catch(() => {});
}

function fileIdentity(): Promise<Ed25519Keypair | null> {
  return readIdentityFile(IDENTITY_FILE);
}

/** Reads or creates the identity in the keyring. Throws if unusable. */
async function keyringIdentity(): Promise<Ed25519Keypair> {
  const current = await keyringRead(SERVICE);
  if (current) return deserialize(current);
  // Every read succeeded and found nothing: a genuine first run.
  const fresh = generateEd25519Keypair();
  await keyringWrite(SERVICE, serialize(fresh));
  return fresh;
}

function fileIdentityForced(): boolean {
  return process.env["BAYA_ALLOW_FILE_IDENTITY"] === "1";
}

let identity: Promise<Ed25519Keypair> | null = null;

/** Returns this computer's long-term identity, creating it on first use. */
export function getOrCreateEd25519Keypair(): Promise<Ed25519Keypair> {
  identity ??= resolveIdentity().catch((error: unknown) => {
    identity = null;
    throw error;
  });
  return identity;
}

async function resolveIdentity(): Promise<Ed25519Keypair> {
  const file = await fileIdentity();
  if (file) return file;

  const forceFile = fileIdentityForced();
  let keyringError: unknown = null;
  if (!forceFile) {
    // A locked Keychain right after wake throws transiently; retry before
    // concluding the keyring is gone.
    for (let attempt = 1; attempt <= KEYRING_ATTEMPTS; attempt++) {
      try {
        return await keyringIdentity();
      } catch (error) {
        keyringError = error;
        if (keyringMissing) break;
        if (attempt < KEYRING_ATTEMPTS) {
          await new Promise((resolve) => setTimeout(resolve, 300 * attempt));
        }
      }
    }
    const coreKeyring =
      !keyringMissing && (process.platform === "darwin" || process.platform === "win32");
    if (coreKeyring) throw new KeyringUnavailableError(keyringError);
    const paired = await listPeers();
    if (paired.length > 0) throw new PairedIdentityMissingError(paired.length, keyringError);
    process.stderr.write(
      `[baya] OS keyring unavailable; storing the identity in ${IDENTITY_FILE}.\n`,
    );
  }

  const fresh = generateEd25519Keypair();
  await writePrivate(IDENTITY_FILE, serialize(fresh));
  return fresh;
}

// ── Paired devices ───────────────────────────────────────────────────────────

export interface PeerRecord {
  name: string;
  /** The phone's Ed25519 Owner key, stored exactly as received. */
  remote_epk: string;
  /** ISO-8601 timestamp. */
  paired_at: string;
}

function canonicalKey(value: unknown): string | null {
  if (typeof value !== "string") return null;
  try {
    return canonicalizeEd25519PublicKey(value);
  } catch {
    return null;
  }
}

function isPeerRecord(value: unknown): value is PeerRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record["name"] === "string" &&
    canonicalKey(record["remote_epk"]) !== null &&
    typeof record["paired_at"] === "string"
  );
}

async function readPeersFile(path: string): Promise<PeerRecord[] | null> {
  try {
    const parsed = JSON.parse(await readFile(path, "utf8")) as { peers?: unknown };
    return Array.isArray(parsed.peers) ? parsed.peers.filter(isPeerRecord) : [];
  } catch {
    return null;
  }
}

// Every outbound frame checks pairing; cache by mtime so streaming does not
// reread the file per chunk while CLI edits from other processes still apply.
let cache: { mtimeMs: number; peers: PeerRecord[] } | null = null;

export async function listPeers(): Promise<PeerRecord[]> {
  const mtimeMs = existsSync(PEERS_FILE) ? statSync(PEERS_FILE).mtimeMs : -1;
  if (cache && cache.mtimeMs === mtimeMs) return cache.peers;
  if (mtimeMs < 0) {
    cache = { mtimeMs, peers: [] };
    return [];
  }
  const peers = (await readPeersFile(PEERS_FILE)) ?? [];
  cache = { mtimeMs, peers };
  return peers;
}

async function writePeers(peers: PeerRecord[]): Promise<PeerRecord[]> {
  await writePrivate(PEERS_FILE, `${JSON.stringify({ peers }, null, 2)}\n`);
  cache = null;
  return peers;
}

let mutations: Promise<unknown> = Promise.resolve();

function mutatePeers<T>(change: (peers: PeerRecord[]) => [PeerRecord[], T]): Promise<T> {
  const run = mutations.then(async () => {
    const [next, result] = change([...(await listPeers())]);
    await writePeers(next);
    return result;
  });
  mutations = run.catch(() => {});
  return run;
}

/** True when `key` belongs to a paired phone, regardless of base64 spelling. */
export function isPairedKey(key: unknown, peers: readonly PeerRecord[]): boolean {
  const canonical = canonicalKey(key);
  return canonical !== null && peers.some((peer) => canonicalKey(peer.remote_epk) === canonical);
}

/** Adds a phone, replacing an earlier pairing of the same key. */
export function addPeer(record: PeerRecord): Promise<void> {
  const key = canonicalKey(record.remote_epk);
  return mutatePeers((peers) => [
    [...peers.filter((peer) => canonicalKey(peer.remote_epk) !== key), record],
    undefined,
  ]);
}

/**
 * Removes paired phones whose name matches exactly or whose key starts with
 * `query`. Returns the removed records.
 */
export function removePeers(query: string): Promise<PeerRecord[]> {
  const needle = query.trim();
  return mutatePeers((peers) => {
    if (!needle) return [peers, []];
    const matches = (peer: PeerRecord) =>
      peer.name === needle ||
      peer.remote_epk.startsWith(needle) ||
      canonicalKey(peer.remote_epk)!.startsWith(needle);
    return [peers.filter((peer) => !matches(peer)), peers.filter(matches)];
  });
}
