import type { Chip } from './types';

/** A named chip shows after this long even if its price hasn't landed yet ("Finding price…"). */
export const SHOW_UNPRICED_MS = 5_000;
/** After this long, the shopper's row for an unpriced chip offers "Add price". */
export const NO_PRICE_MS = 20_000;

/**
 * Items appear on the feed once they are named and priced, or named for SHOW_UNPRICED_MS while the
 * price is still being found; wishes always show; identifying chips never do.
 */
export function visibleChip(c: Chip, opts: { shopper?: boolean; now?: number } = {}): boolean {
  if (c.state === 'removed' || c.dropped) return false;
  if (c.state === 'wish') return true;
  if (c.state === 'identifying' || !c.name.trim()) return false;
  if (c.priceCents !== null) return true;
  return (opts.now ?? Date.now()) - c.addedAt >= SHOW_UNPRICED_MS;
}
