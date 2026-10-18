import { expect, test } from 'vitest';
import { coverage, ringColor, roomFor, splitChip } from '@/lib/share';

test('splitChip parity with server vectors', () => {
  expect([...splitChip(872, ['a', 'b'])]).toEqual([['a', 436], ['b', 436]]);
  expect([...splitChip(800, ['a', 'b', 'c'])]).toEqual([['a', 267], ['b', 267], ['c', 266]]);
  expect([...splitChip(1001, ['a', 'b', 'c'])]).toEqual([['a', 334], ['b', 334], ['c', 333]]);
});
test('roomFor with tax', () => {
  expect(roomFor([100], 1000, 0.1)).toBe(890);
});

const people = [
  { id: 'j', isShopper: true },
  { id: 'p', isShopper: false },
  { id: 'm', isShopper: false },
  { id: 'l', isShopper: false },
];
test('ringColor: me blue, shopper teal, others orange then the palette', () => {
  expect(ringColor(people, 'p', 'p')).toBe('#2B59E8');
  expect(ringColor(people, 'j', 'p')).toBe('#0F7B6C');
  expect(ringColor(people, 'm', 'p')).toBe('#D9480F');
  expect(ringColor(people, 'l', 'p')).toBe('#7048E8');
  expect(ringColor(people, 'p', 'm')).toBe('#D9480F');
  // The shopper sees the first claimer in blue, so colors match the claimers' phones.
  expect(ringColor(people, 'p', 'j')).toBe('#2B59E8');
  expect(ringColor(people, 'm', 'j')).toBe('#D9480F');
});
test('coverage excludes the shopper and counts live priced chips only', () => {
  const ps = [
    { id: 'j', name: 'J', initial: 'J', isShopper: true, authorizedCents: null, authId: null, approvalCode: null, payoutPan: null },
    { id: 'p', name: 'P', initial: 'P', isShopper: false, authorizedCents: 4000, authId: null, approvalCode: null, payoutPan: null },
  ];
  const c = (o: object) => ({ id: 'x', name: 'x', priceCents: 100, priceSource: 'sticker' as const, photoUrl: null, region: null, quantity: 1, claimers: [] as string[], state: 'open' as const, wishedBy: null, duplicateOf: null, putBack: false, dropped: false, overCap: [], removedAt: null, addedAt: 0, ...o });
  const r = coverage(ps, [c({ claimers: ['p', 'j'] }), c({ priceCents: 50, claimers: ['j'] }), c({ putBack: true, claimers: ['p'] }), c({ priceCents: null, claimers: ['p'] })]);
  expect(r).toEqual({ coveredCents: 50, totalCents: 150, segments: [{ id: 'p', name: 'P', cents: 50 }] });
});
