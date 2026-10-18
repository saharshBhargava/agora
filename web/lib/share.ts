// Display-only previews. Same algorithms as server/src/money.ts; the server is the authority.
// All money is integer cents.

const sum = (xs: number[]): number => xs.reduce((a, b) => a + b, 0);

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

/** My share of one chip; a chip with no price yet counts 0. */
export function myShare(priceCents: number | null, claimers: string[], me: string): number {
  if (priceCents === null) return 0;
  return splitChip(priceCents, claimers).get(me) ?? 0;
}

/** Per-person ring colors, picked by index in run.people. "me" always uses --accent. */
export const RING_COLORS = ['#2f7bf6', '#1f9d55', '#8a4fe0', '#d99a00', '#0aa5b5', '#d6458f'];

export function ringColor(people: { id: string }[], id: string, me: string): string {
  if (id === me) return 'var(--accent)';
  const i = Math.max(0, people.findIndex((p) => p.id === id));
  return RING_COLORS[i % RING_COLORS.length];
}
