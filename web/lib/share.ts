// Display-only previews. Same algorithms as server/src/money.ts; the server is the authority.
// All money is integer cents.
import { formatCents } from './money';
import type { Chip, Person, ReceiptState } from './types';

const sum = (xs: number[]): number => xs.reduce((a, b) => a + b, 0);

/** The shopper's stepper runs 1 to 20 (server MAX_QUANTITY). */
export const MAX_QUANTITY = 20;

/**
 * A chip's line total: the receipt's exact total once read, else unit price × quantity; null while
 * unpriced. Same as `lineCents` in server/src/money.ts: every share, room and total uses it.
 */
export function lineCents(chip: Pick<Chip, 'priceCents' | 'quantity' | 'receiptTotalCents'>): number | null {
  if (chip.receiptTotalCents !== undefined && chip.receiptTotalCents !== null) return chip.receiptTotalCents;
  return chip.priceCents === null ? null : chip.priceCents * (chip.quantity ?? 1);
}

/** "×2" for more than one, "" for one. */
export function qtyText(quantity: number): string {
  return quantity > 1 ? `×${quantity}` : '';
}

/** "Cosmic Crisp Apple ×2", or just the name for one. */
export function nameWithQty(chip: Pick<Chip, 'name' | 'quantity'>): string {
  const q = qtyText(chip.quantity);
  return q ? `${chip.name} ${q}` : chip.name;
}

/** The line total, or "~$?" while unpriced. */
export function priceLabel(chip: Pick<Chip, 'priceCents' | 'quantity' | 'receiptTotalCents'>): string {
  const cents = lineCents(chip);
  return cents === null ? '~$?' : formatCents(cents);
}

/** The stepper's next count, or null when it would leave 1 to 20 (that button is disabled). */
export function stepQuantity(quantity: number, delta: 1 | -1): number | null {
  const next = quantity + delta;
  return next < 1 || next > MAX_QUANTITY ? null : next;
}

/** Split a price among claimers: floor share, leftover cents one each to the earliest claimers. */
export function splitChip(priceCents: number, claimerIdsByClaimTime: string[]): Map<string, number> {
  const out = new Map<string, number>();
  const n = claimerIdsByClaimTime.length;
  if (n === 0) return out;
  const base = Math.floor(priceCents / n);
  const leftover = priceCents - base * n;
  claimerIdsByClaimTime.forEach((id, i) => out.set(id, base + (i < leftover ? 1 : 0)));
  return out;
}

/** Cents of authorization left after the tray (with tax); may be negative. */
export function roomFor(trayFullPricesCents: number[], authorizedCents: number, taxRate: number): number {
  return authorizedCents - Math.ceil((sum(trayFullPricesCents) * (10000 + Math.round(taxRate * 10000))) / 10000);
}

/** My share of one chip's line total (`lineCents`); a chip with no price yet counts 0. */
export function myShare(priceCents: number | null, claimers: string[], me: string): number {
  if (priceCents === null) return 0;
  return splitChip(priceCents, claimers).get(me) ?? 0;
}

/** "Me" is always blue; the shopper is always teal. */
export const ME_COLOR = '#2B59E8';
export const SHOPPER_COLOR = '#0F7B6C';
/** Other claimers, in join order. Every color keeps white initials at 4.5:1 or better. */
export const OTHER_COLORS = ['#D9480F', '#7048E8', '#C2255C', '#2F7A1F', '#8A5A00'];
/** Kept for callers that want the whole claimer palette. */
export const RING_COLORS = [ME_COLOR, ...OTHER_COLORS];

/**
 * Per-person color. "me" (a claimer) is always blue and the shopper is always teal. Other claimers take
 * orange, then the small palette, in join order. When the viewer is not a claimer (the shopper), the
 * first claimer takes blue so every claimer keeps one stable color across the claimers' phones.
 */
export function ringColor(people: { id: string; isShopper?: boolean }[], id: string, me: string): string {
  const person = people.find((p) => p.id === id);
  if (person?.isShopper) return SHOPPER_COLOR;
  const meIsClaimer = people.some((p) => p.id === me && !p.isShopper);
  if (id === me && meIsClaimer) return ME_COLOR;
  const claimers = people.filter((p) => !p.isShopper && !(meIsClaimer && p.id === me));
  const palette = meIsClaimer ? OTHER_COLORS : RING_COLORS;
  const i = Math.max(0, claimers.findIndex((p) => p.id === id));
  return palette[i % palette.length];
}

/** The chip border: none = line color, one claimer = their color, several = an even conic split. */
export function chipBorder(people: { id: string; isShopper?: boolean }[], claimers: string[], me: string): string {
  if (claimers.length === 0) return 'var(--line)';
  if (claimers.length === 1) return ringColor(people, claimers[0], me);
  const step = 360 / claimers.length;
  const stops = claimers.map((id, i) => `${ringColor(people, id, me)} ${i * step}deg ${(i + 1) * step}deg`);
  return `conic-gradient(${stops.join(', ')})`;
}

/** A chip that is really in the cart: not a wish, not removed, not identifying, not put back or dropped. */
export function isLiveChip(c: Chip): boolean {
  return c.state !== 'wish' && c.state !== 'removed' && c.state !== 'identifying' && !c.putBack && !c.dropped;
}

export type Coverage = {
  /** Sum of every housemate's share (the shopper's own claims are not covered). */
  coveredCents: number;
  /** Sum of live chip line totals. */
  totalCents: number;
  /** One per housemate with a share, in join order. */
  segments: { id: string; name: string; cents: number }[];
};

/** Shopper preview: how much of the cart the housemates cover, by line totals. Chips without a price count 0. */
export function coverage(people: Person[], chips: Chip[]): Coverage {
  const by = new Map<string, number>();
  let totalCents = 0;
  for (const c of chips) {
    const line = lineCents(c);
    if (!isLiveChip(c) || line === null) continue;
    totalCents += line;
    for (const [id, cents] of splitChip(line, c.claimers)) by.set(id, (by.get(id) ?? 0) + cents);
  }
  const segments = people
    .filter((p) => !p.isShopper && (by.get(p.id) ?? 0) > 0)
    .map((p) => ({ id: p.id, name: p.name, cents: by.get(p.id)! }));
  return { coveredCents: sum(segments.map((s) => s.cents)), totalCents, segments };
}

/** "Priya", "Priya and Marcus", "Priya, Marcus and Lee". */
export function listNames(names: string[]): string {
  if (names.length <= 1) return names[0] ?? '';
  return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}

/**
 * Live chips a receipt line can still be paired with: chips with no line yet, and chips counted more
 * than once whose lines so far cover fewer items than their cart count (the server's rule).
 */
export function pairableChips(receipt: ReceiptState, chips: Chip[]): Chip[] {
  const covered = new Map<string, number>();
  for (const m of receipt.matches) {
    covered.set(m.chipId, (covered.get(m.chipId) ?? 0) + Math.max(1, receipt.lines[m.lineIndex]?.quantity ?? 1));
  }
  return chips.filter((c) => isLiveChip(c) && (covered.get(c.id) ?? 0) < (receipt.cartQuantities?.[c.id] ?? c.quantity));
}
