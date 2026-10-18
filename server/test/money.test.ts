import { describe, expect, it } from 'vitest';
import { allocateTax, capAllows, personTotals, roomFor, splitChip } from '../src/money.js';

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
