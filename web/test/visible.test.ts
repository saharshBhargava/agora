import { describe, expect, it } from 'vitest';
import { SHOW_UNPRICED_MS, visibleChip } from '@/lib/visible';
import type { Chip } from '@/lib/types';

const chip = (over: Partial<Chip>): Chip => ({
  id: 'c', name: 'Apple', priceCents: 110, priceSource: 'web', photoUrl: null, region: null, quantity: 1,
  claimers: [], state: 'open', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
  overCap: [], removedAt: null, addedAt: 0, ...over,
});

describe('visibleChip', () => {
  it('shows only named, priced items and wishes', () => {
    expect(visibleChip(chip({}))).toBe(true);
    expect(visibleChip(chip({ state: 'identifying', name: '' }))).toBe(false);
    expect(visibleChip(chip({ priceCents: null }), { now: 1 })).toBe(false); // too new, no price yet
    expect(visibleChip(chip({ state: 'wish', priceCents: null }))).toBe(true);
    expect(visibleChip(chip({ state: 'removed' }))).toBe(false);
  });
  it('shows a named, unpriced item to everyone after 5 s', () => {
    expect(visibleChip(chip({ priceCents: null }), { now: SHOW_UNPRICED_MS - 1 })).toBe(false);
    expect(visibleChip(chip({ priceCents: null }), { now: SHOW_UNPRICED_MS })).toBe(true);
    expect(visibleChip(chip({ priceCents: null }), { shopper: true, now: SHOW_UNPRICED_MS })).toBe(true);
    expect(visibleChip(chip({ state: 'identifying', name: '', priceCents: null }), { now: 60_000 })).toBe(false);
  });
});
