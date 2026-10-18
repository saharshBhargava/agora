import { describe, expect, it } from 'vitest';
import { allocateTax, capAllows, lineCents, MAX_QUANTITY, personTotals, roomFor, splitChip } from '../src/money.js';

const obj = (m: Map<string, number>) => Object.fromEntries(m);

describe('splitChip', () => {
  it('splits evenly', () => {
    expect(obj(splitChip(872, ['a', 'b']))).toEqual({ a: 436, b: 436 });
  });
  it('gives leftover cents to the earliest claimers', () => {
    expect(obj(splitChip(800, ['a', 'b', 'c']))).toEqual({ a: 267, b: 267, c: 266 });
  });
  it('gives a solo claimer the full price', () => {
    expect(obj(splitChip(2399, ['b']))).toEqual({ b: 2399 });
  });
  it('sums exactly to the price', () => {
    const sum = [...splitChip(1001, ['a', 'b', 'c']).values()].reduce((x, y) => x + y, 0);
    expect(sum).toBe(1001);
  });
  it('returns an empty map for no claimers', () => {
    expect(splitChip(500, []).size).toBe(0);
  });
});

describe('roomFor and capAllows', () => {
  it('computes room', () => {
    expect(roomFor([872], 4000, 0)).toBe(3128);
    expect(roomFor([872, 2399], 4000, 0)).toBe(729);
  });
  it('does not drift a cent on float tax', () => {
    expect(roomFor([1000], 2000, 0.1)).toBe(900);
    expect(capAllows([], 1000, 1100, 0.1)).toBe(true);
  });
  it('rejects a chip that would exceed the cap', () => {
    expect(capAllows([872, 2399], 2399, 4000, 0)).toBe(false);
    expect(capAllows([], 3999, 4000, 0.1)).toBe(false);
  });
  it('allows a chip that fits', () => {
    expect(capAllows([872], 2399, 4000, 0)).toBe(true);
  });
});

describe('allocateTax', () => {
  it('allocates pro rata with leftover to the largest line', () => {
    const out = allocateTax([800, 2200], 271);
    expect(out).toEqual([72, 199]);
    expect(out.reduce((x, y) => x + y, 0)).toBe(271);
  });
});

describe('personTotals', () => {
  it('sums each person across chips', () => {
    const totals = personTotals([
      { priceCents: 872, claimers: ['a', 'b'] },
      { priceCents: 2399, claimers: ['b'] },
    ]);
    expect(obj(totals)).toEqual({ a: 436, b: 2835 });
  });
});

describe('roomFor regression', () => {
  it('keeps tax in integer basis points', () => {
    expect(roomFor([100], 1000, 0.1)).toBe(890);
  });
});

describe('quantity: lineCents and personTotals', () => {
  it('a line total is the unit price times the quantity; unpriced is null', () => {
    expect(lineCents({ priceCents: 110, quantity: 2 })).toBe(220);
    expect(lineCents({ priceCents: 110, quantity: 1 })).toBe(110);
    expect(lineCents({ priceCents: null, quantity: 3 })).toBeNull();
  });
  it('a quantity missing from an older stored chip counts as 1', () => {
    expect(lineCents({ priceCents: 429 })).toBe(429);
  });
  it("the receipt's exact total wins over unit times quantity", () => {
    expect(lineCents({ priceCents: 110, quantity: 2, receiptTotalCents: 219 })).toBe(219);
    expect(lineCents({ priceCents: 110, quantity: 2, receiptTotalCents: null })).toBe(220);
  });
  it('personTotals splits the line total, leftover cents to the earliest claimers', () => {
    const totals = personTotals([{ priceCents: 110, quantity: 2, claimers: ['a', 'b', 'c'] }]);
    expect(obj(totals)).toEqual({ a: 74, b: 73, c: 73 });
  });
  it('caps a quantity at 20', () => {
    expect(MAX_QUANTITY).toBe(20);
  });
});
