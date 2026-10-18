// Receipt matching, tax allocation and the resumable settle sequence. All money is integer cents.
import { allocateTax } from './money.js';
import type { PaymentsProvider } from './payments/provider.js';
import { sharesFor } from './run.js';
import type { Chip, PersonSettle, ReceiptLine, ReceiptState, Run } from './types.js';

const THRESHOLD = 0.5;
const ABBREVIATIONS: Record<string, string> = { ks: 'kirkland', twl: 'towels', towel: 'towels' };
const UNIT_WORDS = new Set(['pk', 'ct']);

export function parseReceiptLines(raw: { text: string; cents: number; quantity: number }[]): ReceiptLine[] {
  return raw.map((l) => ({ text: l.text, cents: l.cents, quantity: l.quantity, isTax: /\btax\b/i.test(l.text) }));
}

function tokens(text: string): Set<string> {
  const out = new Set<string>();
  for (const raw of text.toLowerCase().split(/[^a-z0-9]+/)) {
    const t = raw.replace(/^(\d+)(ct|pk)$/, '$1');
    if (t === '' || UNIT_WORDS.has(t)) continue;
    out.add(ABBREVIATIONS[t] ?? t);
  }
  return out;
}

function confidence(line: string, chipName: string): number {
  const chipTokens = tokens(chipName);
  if (chipTokens.size === 0) return 0;
  const lineTokens = tokens(line);
  let hit = 0;
  for (const t of chipTokens) if (lineTokens.has(t)) hit += 1;
  return hit / chipTokens.size;
}

/** Chips a receipt line can pay for. */
export const isLive = (c: Chip): boolean =>
  c.state !== 'wish' && c.state !== 'removed' && c.state !== 'identifying' && !c.putBack && !c.dropped;

type Pair = { chipId: string; lineIndex: number; confidence: number };

/** Only proposals naming a live chip, a real non-tax line and a confidence in [0.5, 1] survive. */
function validProposals(proposals: readonly unknown[], lines: ReceiptLine[], chipIds: Set<string>): Pair[] {
  const out: Pair[] = [];
  for (const p of proposals) {
    if (typeof p !== 'object' || p === null) continue;
    const { lineIndex, chipId, confidence: conf } = p as Record<string, unknown>;
    if (typeof lineIndex !== 'number' || !Number.isInteger(lineIndex) || lineIndex < 0 || lineIndex >= lines.length) continue;
    if (lines[lineIndex].isTax) continue;
    if (typeof chipId !== 'string' || !chipIds.has(chipId)) continue;
    if (typeof conf !== 'number' || !Number.isFinite(conf) || conf < THRESHOLD || conf > 1) continue;
    out.push({ chipId, lineIndex, confidence: conf });
  }
  return out;
}

/** How many items each live chip counted in the cart before any receipt changed its count. */
function cartQuantities(run: Run): Record<string, number> {
  const before = run.receipt?.cartQuantities ?? {};
  return Object.fromEntries(run.chips.filter(isLive).map((c) => [c.id, before[c.id] ?? c.quantity ?? 1]));
}

/** Items a receipt line stands for. */
const lineItems = (line: ReceiptLine): number => Math.max(1, line.quantity);

/**
 * Pairs receipt lines with live chips. `proposals` (a model's matches; untrusted) are validated and
 * taken first, best confidence first; the token-overlap matcher fills whatever they left. A line covers
 * at most `quantity` chips (one unless it says more), and a chip takes lines until they add up to its
 * cart count: one line for one item, or two "APPLE" lines for an apple counted twice.
 */
export function matchReceipt(run: Run, lines: ReceiptLine[], proposals?: readonly unknown[] | null): ReceiptState {
  const chips = run.chips.filter(isLive);
  const counts = cartQuantities(run);
  const covered = new Map<string, number>();
  const full = (chipId: string): boolean => (covered.get(chipId) ?? 0) >= (counts[chipId] ?? 1);
  const lineUse = new Map<number, number>();
  const matches: ReceiptState['matches'] = [];
  const take = (pairs: Pair[], capacity: (lineIndex: number) => number): void => {
    pairs.sort((a, b) => b.confidence - a.confidence || a.lineIndex - b.lineIndex);
    for (const p of pairs) {
      const used = lineUse.get(p.lineIndex) ?? 0;
      if (full(p.chipId) || used >= capacity(p.lineIndex)) continue;
      if (matches.some((m) => m.chipId === p.chipId && m.lineIndex === p.lineIndex)) continue;
      covered.set(p.chipId, (covered.get(p.chipId) ?? 0) + lineItems(lines[p.lineIndex]));
      lineUse.set(p.lineIndex, used + 1);
      matches.push(p);
    }
  };

  if (proposals) {
    take(validProposals(proposals, lines, new Set(chips.map((c) => c.id))), (i) => lineItems(lines[i]));
  }
  const overlap: Pair[] = [];
  lines.forEach((line, lineIndex) => {
    if (line.isTax || lineUse.has(lineIndex)) return;
    for (const c of chips) {
      if (full(c.id)) continue;
      const conf = confidence(line.text, c.name);
      if (conf >= THRESHOLD) overlap.push({ chipId: c.id, lineIndex, confidence: conf });
    }
  });
  take(overlap, () => 1);

  matches.sort((a, b) => a.lineIndex - b.lineIndex);
  const unmatchedLines = lines.flatMap((l, i) => (l.isTax || lineUse.has(i) ? [] : [i]));
  return { lines, matches, unmatchedLines };
}

/** Splits `cents` by integer weights: floor each part, leftover cents one each to the earliest. */
function splitWeighted(cents: number, weights: number[]): number[] {
  const total = weights.reduce((a, w) => a + w, 0);
  if (total === 0) return weights.map(() => 0);
  const out = weights.map((w) => Math.floor((cents * w) / total));
  let leftover = cents - out.reduce((a, x) => a + x, 0);
  for (let i = 0; leftover > 0; i = (i + 1) % out.length) {
    out[i] += 1;
    leftover -= 1;
  }
  return out;
}

/**
 * Prices matched chips from the receipt and sets chip states; claims are kept. A chip's money is the
 * exact sum of its lines plus their pro rata tax (`receiptTotalCents`); `priceCents` becomes the unit
 * for display. The receipt's count wins: a chip whose lines are its own takes their quantity. A line
 * covering several chips splits by their counts. A chip left without a line goes back to its cart count.
 */
function priceFromReceipt(run: Run, receipt: ReceiptState): Run {
  const counts = receipt.cartQuantities ?? cartQuantities(run);
  const countOf = (c: Chip): number => counts[c.id] ?? c.quantity ?? 1;
  const taxCents = receipt.lines.filter((l) => l.isTax).reduce((a, l) => a + l.cents, 0);
  // Tax is spread over every purchased line, matched or not; lines nobody claimed (and "Mine" lines)
  // keep their share with the shopper, so a claimer never pays tax on the shopper's own items.
  const purchased = receipt.lines.flatMap((l, i) => (l.isTax ? [] : [i]));
  const lineTax = new Map<number, number>();
  allocateTax(purchased.map((i) => receipt.lines[i].cents), taxCents).forEach((t, k) => lineTax.set(purchased[k], t));

  const chipsByLine = new Map<number, string[]>();
  for (const m of receipt.matches) chipsByLine.set(m.lineIndex, [...(chipsByLine.get(m.lineIndex) ?? []), m.chipId]);
  const byId = new Map(run.chips.map((c) => [c.id, c]));
  const totals = new Map<string, number>();
  const items = new Map<string, number>();
  const shared = new Set<string>();
  for (const [lineIndex, ids] of chipsByLine) {
    const weights = ids.map((id) => {
      const c = byId.get(id);
      return c ? countOf(c) : 1;
    });
    const line = splitWeighted(receipt.lines[lineIndex].cents, weights);
    const tax = splitWeighted(lineTax.get(lineIndex) ?? 0, weights);
    ids.forEach((id, k) => {
      totals.set(id, (totals.get(id) ?? 0) + line[k] + tax[k]);
      if (ids.length === 1) items.set(id, (items.get(id) ?? 0) + lineItems(receipt.lines[lineIndex]));
      else shared.add(id);
    });
  }
  return {
    ...run,
    receipt: { ...receipt, cartQuantities: counts },
    state: 'receipt',
    chips: run.chips.map((c) => {
      const total = totals.get(c.id);
      if (total !== undefined) {
        const quantity = shared.has(c.id) ? countOf(c) : (items.get(c.id) ?? countOf(c));
        return {
          ...c, quantity, priceCents: Math.round(total / quantity), receiptTotalCents: total,
          priceSource: 'receipt', state: 'matched',
        };
      }
      return isLive(c) ? { ...c, state: 'unmatched', quantity: countOf(c), receiptTotalCents: null } : c;
    }),
  };
}

export function applyReceipt(run: Run, receipt: ReceiptState): Run {
  return priceFromReceipt(run, receipt);
}

/** Every non-tax line that is neither paired with a chip nor marked Mine. */
function stillUnmatched(receipt: ReceiptState, matches: ReceiptState['matches'], mine: number[]): number[] {
  const paired = new Set(matches.map((m) => m.lineIndex));
  return receipt.lines.flatMap((l, i) => (l.isTax || paired.has(i) || mine.includes(i) ? [] : [i]));
}

export function fixReceiptLine(run: Run, lineIndex: number, target: { chipId: string } | 'mine'): Run {
  const receipt = run.receipt;
  if (!receipt || !receipt.lines[lineIndex] || receipt.lines[lineIndex].isTax) return run;
  if (target === 'mine') {
    const matches = receipt.matches.filter((m) => m.lineIndex !== lineIndex);
    const mine = [...new Set([...(receipt.mine ?? []), lineIndex])];
    return priceFromReceipt(run, { ...receipt, matches, unmatchedLines: stillUnmatched(receipt, matches, mine), mine });
  }
  const chip = run.chips.find((c) => c.id === target.chipId && isLive(c));
  if (!chip) return run;
  // The line moves from any earlier pairing. The chip keeps its other lines while they and this one
  // add up to no more than its cart count (a second "APPLE" line for an apple counted twice);
  // otherwise it moves off them and they become unmatched again.
  const count = receipt.cartQuantities?.[chip.id] ?? chip.quantity ?? 1;
  const others = receipt.matches.filter((m) => m.chipId === chip.id && m.lineIndex !== lineIndex);
  const otherItems = others.reduce((a, m) => a + lineItems(receipt.lines[m.lineIndex]), 0);
  const keepOthers = otherItems + lineItems(receipt.lines[lineIndex]) <= count;
  const kept = receipt.matches.filter((m) => m.lineIndex !== lineIndex && (keepOthers || m.chipId !== chip.id));
  const matches = [...kept, { chipId: chip.id, lineIndex, confidence: 1 }].sort((a, b) => a.lineIndex - b.lineIndex);
  const mine = (receipt.mine ?? []).filter((i) => i !== lineIndex);
  return priceFromReceipt(run, {
    ...receipt,
    matches,
    unmatchedLines: stillUnmatched(receipt, matches, mine),
    ...(mine.length > 0 || receipt.mine ? { mine } : {}),
  });
}

const fresh = (shareCents: number, approvalCode: string | null = null): PersonSettle => ({
  step: 'joined', shareCents, capturedCents: 0, releasedCents: 0, owedCents: 0,
  approvalCode, captureId: null, error: null,
});

const isTerminal = (s: PersonSettle | undefined): boolean =>
  s !== undefined && (s.step === 'captured' || (s.step === 'reversed' && s.shareCents === 0));

export async function settle(
  run: Run,
  provider: PaymentsProvider,
  ref: (personId: string, step: string) => string,
  persist: (run: Run) => Promise<void>,
): Promise<Run> {
  let cur: Run = {
    ...run,
    chips: run.chips.map((c) => (c.state === 'unmatched' && c.claimers.length > 0 ? { ...c, claimers: [] } : c)),
  };
  const shares = sharesFor(cur);

  const write = async (id: string, patch: Partial<PersonSettle>, authorizedCents?: number): Promise<void> => {
    const prev = cur.settle[id] ?? fresh(shares.get(id) ?? 0, cur.people.find((x) => x.id === id)?.approvalCode ?? null);
    cur = {
      ...cur,
      settle: { ...cur.settle, [id]: { ...prev, ...patch } },
      people: authorizedCents === undefined
        ? cur.people
        : cur.people.map((p) => (p.id === id ? { ...p, authorizedCents } : p)),
    };
    await persist(cur);
  };

  for (const p of cur.people) {
    if (p.isShopper || isTerminal(cur.settle[p.id])) continue;
    const share = shares.get(p.id) ?? 0;
    try {
      await write(p.id, { step: 'settling', shareCents: share, error: null });
      let authorized = p.authorizedCents ?? 0;
      if (p.authId === null || p.authorizedCents === null) {
        if (share > 0) throw new Error('no authorization');
        await write(p.id, { step: 'reversed' });
        continue;
      }
      let capturable = Math.min(share, authorized);
      if (share > authorized) {
        const inc = await provider.incremental(ref(p.id, 'incremental'), p.authId, share - authorized);
        if (inc.status === 'AUTHORIZED') {
          authorized = inc.authorizedCents;
          capturable = Math.min(share, authorized);
          await write(p.id, { step: 'incremented', approvalCode: inc.approvalCode }, authorized);
        }
      }
      const done = cur.settle[p.id];
      const toRelease = authorized - capturable - done.releasedCents;
      if (toRelease > 0) {
        const rev = await provider.reverse(ref(p.id, 'reverse'), p.authId, toRelease);
        await write(p.id, { step: 'reversed', releasedCents: done.releasedCents + rev.reversedCents });
      } else if (share === 0) {
        await write(p.id, { step: 'reversed' });
      }
      if (capturable > 0) {
        const cap = await provider.capture(ref(p.id, 'capture'), p.authId, capturable);
        await write(p.id, { step: 'captured', capturedCents: capturable, owedCents: share - capturable, captureId: cap.captureId });
      }
    } catch (e) {
      await write(p.id, { step: 'failed', error: e instanceof Error ? e.message : String(e) });
    }
  }

  const claimers = cur.people.filter((p) => !p.isShopper);
  const allTerminal = claimers.every((p) => isTerminal(cur.settle[p.id]));
  if (!allTerminal) {
    cur = { ...cur, state: 'partlySettled' };
    await persist(cur);
    return cur;
  }
  const owed = claimers.some((p) => (cur.settle[p.id]?.owedCents ?? 0) > 0);
  const shopper = cur.people.find((p) => p.id === cur.shopperId);
  const total = claimers.reduce((a, p) => a + (cur.settle[p.id]?.capturedCents ?? 0), 0);
  let payoutFailed = false;
  if (cur.payout === null && total > 0) {
    try {
      if (!shopper?.payoutPan) throw new Error('no payout card');
      const payout = await provider.payout(ref(cur.shopperId, 'payout'), shopper.payoutPan, total);
      cur = { ...cur, payout };
    } catch {
      payoutFailed = true;
    }
  }
  cur = { ...cur, state: owed || payoutFailed ? 'partlySettled' : 'settled' };
  await persist(cur);
  return cur;
}
