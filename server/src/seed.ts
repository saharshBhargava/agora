import { randomUUID } from 'node:crypto';
import { createRun } from './run.js';
import type { Run } from './types.js';

/**
 * Demo run: shopper Jake at STORE_NAME (default costco), no chips; claimers join through the API.
 * The shopper's id is random per run (ids are public; the shopper's key is what grants shopper rights).
 */
export function seedRun(now: number): Run {
  return createRun({ id: randomUUID(), name: 'Jake', initial: 'J', payoutPan: '4111111111111111' }, process.env.STORE_NAME || 'costco', '4111111111111111', now);
}
