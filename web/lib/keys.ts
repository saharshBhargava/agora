// This browser's secret key for each person it holds in a run. The server hands a key out once, from
// create run or join, and every action as that person must carry it (REST header, WebSocket query).
// Person ids are public (every run snapshot lists them), so the key is what proves "I am this person".

const prefix = 'dibs.key.';
const slot = (runId: string, personId: string) => `${prefix}${runId}.${personId}`;
/** Fallback for private windows, where localStorage throws: the key lasts as long as the tab. */
const memory = new Map<string, string>();

export function saveKey(runId: string, personId: string, key: string): void {
  memory.set(slot(runId, personId), key);
  try {
    localStorage.setItem(slot(runId, personId), key);
  } catch {
    /* storage blocked: memory still has it */
  }
}

export function keyFor(runId: string, personId: string): string | null {
  try {
    const stored = localStorage.getItem(slot(runId, personId));
    if (stored) return stored;
  } catch {
    /* storage blocked */
  }
  return memory.get(slot(runId, personId)) ?? null;
}

/**
 * A link can carry the key in its fragment (`#key=...`, never sent to the server), for opening a run on
 * another device, e.g. the shopper link for a run created with curl. Saves it and strips it from the URL.
 */
export function adoptKeyFromHash(runId: string, personId: string): void {
  if (typeof window === 'undefined') return;
  const hash = window.location.hash.replace(/^#/, '');
  const key = new URLSearchParams(hash).get('key');
  if (!key) return;
  saveKey(runId, personId, key);
  try {
    window.history.replaceState(window.history.state, '', window.location.pathname + window.location.search);
  } catch {
    /* the key is saved either way */
  }
}

/** Test hook: forget every key. */
export function clearKeys(): void {
  memory.clear();
  try {
    for (const k of Object.keys(localStorage)) if (k.startsWith(prefix)) localStorage.removeItem(k);
  } catch {
    /* storage blocked */
  }
}
