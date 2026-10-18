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
  return authorizedCents - Math.ceil(sum(trayFullPricesCents) * (1 + taxRate));
}

/** True if adding the candidate chip keeps the tray within the authorization. */
export function capAllows(
  trayFullPricesCents: number[],
  candidateFullPriceCents: number,
  authorizedCents: number,
  taxRate: number,
): boolean {
  return roomFor([...trayFullPricesCents, candidateFullPriceCents], authorizedCents, taxRate) >= 0;
}

/** Pro rata tax by line amount: floor, leftover cents to the largest lines first. */
export function allocateTax(lineCents: number[], taxCents: number): number[] {
  const total = sum(lineCents);
  if (total === 0) return lineCents.map(() => 0);
  const out = lineCents.map((line) => Math.floor((line * taxCents) / total));
  let leftover = taxCents - sum(out);
  const order = lineCents.map((_, i) => i).sort((a, b) => lineCents[b] - lineCents[a] || a - b);
  for (let k = 0; leftover > 0; k = (k + 1) % order.length) {
    out[order[k]] += 1;
    leftover -= 1;
  }
  return out;
}

/** Each person's total across chips, splitting each chip among its claimers. */
export function personTotals(chips: { priceCents: number; claimers: string[] }[]): Map<string, number> {
  const totals = new Map<string, number>();
  for (const chip of chips) {
    for (const [id, cents] of splitChip(chip.priceCents, chip.claimers)) {
      totals.set(id, (totals.get(id) ?? 0) + cents);
    }
  }
  return totals;
}
