// Per-person secret keys. Person ids are public (every run snapshot lists them, the UI needs them), so
// a key is what proves a caller is that person. A key is handed out once, by create run (the shopper)
// or join (a claimer), and only its SHA-256 is kept, in DATA_DIR/keys.json, never in the run itself.
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/** 32 random bytes, base64url (43 characters). */
export const newKey = (): string => randomBytes(32).toString('base64url');
export const hashKey = (key: string): string => createHash('sha256').update(key).digest('hex');

export type Keyring = ReturnType<typeof createKeyring>;

/** runId → personId → sha256(key), persisted like the runs (atomic file, a failed write is logged). */
export function createKeyring(dataDir: string) {
  const file = join(dataDir, 'keys.json');
  let hashes: Record<string, Record<string, string>> = {};
  if (existsSync(file)) {
    try {
      hashes = JSON.parse(readFileSync(file, 'utf8')) as typeof hashes;
    } catch {
      // A corrupt file starts empty: those runs read as runs from before keys.
    }
  }

  function snapshot(): void {
    try {
      mkdirSync(dataDir, { recursive: true });
      const tmp = `${file}.tmp`;
      writeFileSync(tmp, JSON.stringify(hashes));
      renameSync(tmp, file);
    } catch (e) {
      console.error('key snapshot failed', e);
    }
  }

  return {
    /** Makes a key for the person, keeps its hash, and returns the key (the only time it exists in full). */
    issue(runId: string, personId: string): string {
      const key = newKey();
      hashes[runId] = { ...hashes[runId], [personId]: hashKey(key) };
      snapshot();
      return key;
    },
    /** False for a run created before keys existed: nobody in it can prove who they are. */
    has(runId: string): boolean {
      return Object.keys(hashes[runId] ?? {}).length > 0;
    },
    /** The person this key belongs to in the run, or null. */
    owner(runId: string, key: unknown): string | null {
      if (typeof key !== 'string' || key.length === 0 || key.length > 200) return null;
      const want = Buffer.from(hashKey(key), 'hex');
      for (const [personId, h] of Object.entries(hashes[runId] ?? {})) {
        const have = Buffer.from(h, 'hex');
        if (have.length === want.length && timingSafeEqual(have, want)) return personId;
      }
      return null;
    },
  };
}
