// WebSocket message shapes. Client -> server messages act on one chip; server -> client carry run state.
import type { Box, Run } from './types.js';

export type ClientMsg =
  | { t: 'claim' | 'leave' | 'remove' | 'undoRemove'; chipId: string }
  | { t: 'frame'; jpegBase64: string; at: number; detect?: boolean }
  | { t: 'identifyAt'; x: number; y: number };

export type ServerMsg =
  | { t: 'run'; run: Run }
  | { t: 'error'; reason: string }
  | { t: 'lastCall'; endsAt: number }
  | { t: 'locked' }
  | { t: 'frame'; jpegBase64: string; at: number }
  | { t: 'identifying'; region: Box };

const CLIENT_TYPES = new Set(['claim', 'leave', 'remove', 'undoRemove']);

export function parseClientMsg(raw: string): ClientMsg | null {
  try {
    const m = JSON.parse(raw) as Record<string, unknown>;
    if (typeof m.t !== 'string') return null;
    if (CLIENT_TYPES.has(m.t) && typeof m.chipId === 'string') return m as ClientMsg;
    if (m.t === 'frame' && typeof m.jpegBase64 === 'string' && typeof m.at === 'number') return m as ClientMsg;
    if (m.t === 'identifyAt' && Number.isFinite(m.x) && Number.isFinite(m.y)) return m as ClientMsg;
  } catch {
    // fall through
  }
  return null;
}
