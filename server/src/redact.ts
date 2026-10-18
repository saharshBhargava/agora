// What a run looks like when it leaves the server (REST replies and WebSocket snapshots). The stored
// run keeps full card numbers and authorization ids for the payments calls; nobody else needs them.
import type { Run } from './types.js';

/** "•••• 1111": the last four digits only. */
export function maskPan(pan: string | null): string | null {
  return pan === null ? null : `•••• ${pan.slice(-4)}`;
}

/** The run with authorization ids removed and card numbers masked. Never mutates `run`. */
export function publicRun(run: Run): Run {
  return {
    ...run,
    people: run.people.map((p) => ({ ...p, authId: null, payoutPan: maskPan(p.payoutPan) })),
    payout: run.payout ? { ...run.payout, recipientPan: maskPan(run.payout.recipientPan) ?? '' } : null,
  };
}

/** True for a value shaped like a Run (the REST hook redacts these). */
export function isRun(v: unknown): v is Run {
  if (typeof v !== 'object' || v === null) return false;
  const r = v as Record<string, unknown>;
  return typeof r.shopperId === 'string' && Array.isArray(r.people) && Array.isArray(r.chips);
}
