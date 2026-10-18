// Receipt matching, tax allocation and the resumable settle sequence. All money is integer cents.
import { allocateTax, splitChip } from './money.js';
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

/**
 * Pairs receipt lines with live chips. `proposals` (a model's matches; untrusted) are validated and
 * taken first, best confidence first; the token-overlap matcher fills whatever they left. Each chip
 * gets at most one line, and a line covers at most `quantity` chips (one unless it says more).
 */
export function matchReceipt(run: Run, lines: ReceiptLine[], proposals?: readonly unknown[] | null): ReceiptState {
  const chips = run.chips.filter(isLive);
  const usedChips = new Set<string>();
  const lineUse = new Map<number, number>();
  const matches: ReceiptState['matches'] = [];
  const take = (pairs: Pair[], capacity: (lineIndex: number) => number): void => {
    pairs.sort((a, b) => b.confidence - a.confidence || a.lineIndex - b.lineIndex);
    for (const p of pairs) {
      const used = lineUse.get(p.lineIndex) ?? 0;
      if (usedChips.has(p.chipId) || used >= capacity(p.lineIndex)) continue;
      usedChips.add(p.chipId);
      lineUse.set(p.lineIndex, used + 1);
      matches.push(p);
    }
  };

  if (proposals) {
    take(validProposals(proposals, lines, new Set(chips.map((c) => c.id))), (i) => Math.max(1, lines[i].quantity));
  }
  const overlap: Pair[] = [];
  lines.forEach((line, lineIndex) => {
    if (line.isTax || lineUse.has(lineIndex)) return;
    for (const c of chips) {
      if (usedChips.has(c.id)) continue;
      const conf = confidence(line.text, c.name);
      if (conf >= THRESHOLD) overlap.push({ chipId: c.id, lineIndex, confidence: conf });
    }
  });
  take(overlap, () => 1);

  matches.sort((a, b) => a.lineIndex - b.lineIndex);
  const unmatchedLines = lines.flatMap((l, i) => (l.isTax || lineUse.has(i) ? [] : [i]));
  return { lines, matches, unmatchedLines };
}

/** Prices matched chips from the receipt (line plus pro rata tax) and sets chip states. Claims are kept. */
function priceFromReceipt(run: Run, receipt: ReceiptState): Run {
  const taxCents = receipt.lines.filter((l) => l.isTax).reduce((a, l) => a + l.cents, 0);
  // A line covering several chips (quantity > 1) splits its total among them.
  const chipsByLine = new Map<number, string[]>();
  for (const m of receipt.matches) chipsByLine.set(m.lineIndex, [...(chipsByLine.get(m.lineIndex) ?? []), m.chipId]);
  const lineCents = receipt.matches.map(
    (m) => splitChip(receipt.lines[m.lineIndex].cents, chipsByLine.get(m.lineIndex) ?? [m.chipId]).get(m.chipId) ?? 0,
  );
  // Tax is spread over every purchased line, matched or not; lines nobody claimed (and "Mine" lines)
  // keep their share with the shopper, so a claimer never pays tax on the shopper's own items.
  const purchased = receipt.lines.flatMap((l, i) => (l.isTax ? [] : [i]));
  const lineTax = new Map<number, number>();
  allocateTax(purchased.map((i) => receipt.lines[i].cents), taxCents).forEach((t, k) => lineTax.set(purchased[k], t));
  const priceByChip = new Map<string, number>();
  receipt.matches.forEach((m, i) => {
    const tax = splitChip(lineTax.get(m.lineIndex) ?? 0, chipsByLine.get(m.lineIndex) ?? [m.chipId]).get(m.chipId) ?? 0;
    priceByChip.set(m.chipId, lineCents[i] + tax);
  });
  return {
    ...run,
    receipt,
    state: 'receipt',
    chips: run.chips.map((c) => {
      const price = priceByChip.get(c.id);
      if (price !== undefined) return { ...c, priceCents: price, priceSource: 'receipt', state: 'matched' };
      return isLive(c) ? { ...c, state: 'unmatched' } : c;
    }),
  };
}

export function applyReceipt(run: Run, receipt: ReceiptState): Run {
  return priceFromReceipt(run, receipt);
}

export function fixReceiptLine(run: Run, lineIndex: number, target: { chipId: string } | 'mine'): Run {
  const receipt = run.receipt;
  if (!receipt || !receipt.lines[lineIndex] || receipt.lines[lineIndex].isTax) return run;
  if (target === 'mine') {
    const matches = receipt.matches.filter((m) => m.lineIndex !== lineIndex);
    const mine = [...new Set([...(receipt.mine ?? []), lineIndex])];
    const unmatchedLines = receipt.unmatchedLines.filter((i) => i !== lineIndex);
    return priceFromReceipt(run, { ...receipt, matches, unmatchedLines, mine });
  }
  if (!run.chips.some((c) => c.id === target.chipId && isLive(c))) return run;
  // The chip and the line each move from any earlier pairing; a freed line becomes unmatched again.
  const freed = receipt.matches.filter((m) => m.chipId === target.chipId || m.lineIndex === lineIndex).map((m) => m.lineIndex);
  const kept = receipt.matches.filter((m) => m.chipId !== target.chipId && m.lineIndex !== lineIndex);
  const matches = [...kept, { chipId: target.chipId, lineIndex, confidence: 1 }].sort((a, b) => a.lineIndex - b.lineIndex);
  const unmatchedLines = [...new Set([...receipt.unmatchedLines, ...freed])]
    .filter((i) => i !== lineIndex)
    .sort((a, b) => a - b);
  const mine = (receipt.mine ?? []).filter((i) => i !== lineIndex);
  return priceFromReceipt(run, { ...receipt, matches, unmatchedLines, ...(mine.length > 0 || receipt.mine ? { mine } : {}) });
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
