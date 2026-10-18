import type { Chip } from './types';

/** After this long, a named chip that never got a price shows for the shopper with "Add price". */
export const NO_PRICE_MS = 20_000;

/**
 * Items appear on the feed only once they are named and priced; wishes always show.
 * The shopper also sees a named, still unpriced chip after NO_PRICE_MS so it can be fixed by hand.
 */
export function visibleChip(c: Chip, opts: { shopper?: boolean; now?: number } = {}): boolean {
  if (c.state === 'removed' || c.dropped) return false;
  if (c.state === 'wish') return true;
  if (c.state === 'identifying' || !c.name.trim()) return false;
  if (c.priceCents !== null) return true;
  return !!opts.shopper && (opts.now ?? Date.now()) - c.addedAt >= NO_PRICE_MS;
}
