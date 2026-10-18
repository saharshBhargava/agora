// WebSocket message shapes. Client -> server messages act on one chip; server -> client carry run state.
import type { Run } from './types.js';

export type ClientMsg = { t: 'claim' | 'leave' | 'remove' | 'undoRemove'; chipId: string };

export type ServerMsg =
  | { t: 'run'; run: Run }
  | { t: 'error'; reason: string }
  | { t: 'lastCall'; endsAt: number }
  | { t: 'locked' };

const CLIENT_TYPES = new Set(['claim', 'leave', 'remove', 'undoRemove']);

export function parseClientMsg(raw: string): ClientMsg | null {
  try {
    const m = JSON.parse(raw) as { t?: unknown; chipId?: unknown };
    if (typeof m.t === 'string' && CLIENT_TYPES.has(m.t) && typeof m.chipId === 'string') return m as ClientMsg;
  } catch {
    // fall through
  }
  return null;
}
