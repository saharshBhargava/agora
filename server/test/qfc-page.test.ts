import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { matchProduct, parseQfcPage } from '../src/price/qfc-page.js';

const page = readFileSync(join(import.meta.dirname, 'fixtures', 'qfc-cosmic-crisp.txt'), 'utf8');

describe('parseQfcPage', () => {
  it('reads products with their price and each price', () => {
    const ps = parseQfcPage(page);
    expect(ps[0]).toEqual({ name: 'Kroger® Cosmic Crisp® Apples - 3 Pound Bag', priceCents: 699, eachCents: null });
    expect(ps).toContainEqual({ name: 'Large Cosmic Crisp® Apple – Each', priceCents: 110, eachCents: 110 });
    expect(ps).toContainEqual({ name: 'Kroger® Cosmic Crisp® Apples - 4 Pack Tray', priceCents: 400, eachCents: null });
  });
  it('takes the sale price, the first price shown', () => {
    const ps = parseQfcPage('5 results\n$4.99\n$6.99\nSale: $4.99 discounted from $6.99\nPrivate Selection® Fresh Colossal Blueberries\n9.8 oz\nSNAP EBT');
    expect(ps).toEqual([{ name: 'Private Selection® Fresh Colossal Blueberries', priceCents: 499, eachCents: null }]);
  });
});

describe('matchProduct', () => {
  const ps = parseQfcPage(page);
  it('prefers a single apple over bags and trays', () => {
    expect(matchProduct('Cosmic Crisp Apple', ps)?.priceCents).toBe(110);
  });
  it('returns null when nothing matches well', () => {
    expect(matchProduct('Lawrys Casero Onion Powder', ps)).toBeNull();
  });
  it('matches packs when the item says pack', () => {
    const cans = parseQfcPage('9 results\n$11.99\n$11.99\nCoca-Cola® Zero Sugar Soda Cans 12 pk / 12 fl oz\n12 pk / 12 fl oz\n$3.49\n$3.49\nCoca-Cola® Zero Sugar Soda Bottle 2 liter\n2 L');
    expect(matchProduct('Coca-Cola Zero Sugar 12 pack', cans)?.priceCents).toBe(1199);
    expect(matchProduct('Coca-Cola Zero Sugar', cans)).not.toBeNull();
  });
});
