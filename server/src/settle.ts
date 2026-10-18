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

const isLive = (c: Chip): boolean =>
  c.state !== 'wish' && c.state !== 'removed' && c.state !== 'identifying' && !c.putBack && !c.dropped;

export function matchReceipt(run: Run, lines: ReceiptLine[]): ReceiptState {
  const chips = run.chips.filter(isLive);
  const pairs: { chipId: string; lineIndex: number; confidence: number }[] = [];
  lines.forEach((line, lineIndex) => {
    if (line.isTax) return;
    for (const c of chips) {
      const conf = confidence(line.text, c.name);
      if (conf >= THRESHOLD) pairs.push({ chipId: c.id, lineIndex, confidence: conf });
    }
  });
  pairs.sort((a, b) => b.confidence - a.confidence || a.lineIndex - b.lineIndex);
  const usedChips = new Set<string>();
  const usedLines = new Set<number>();
  const matches: ReceiptState['matches'] = [];
  for (const p of pairs) {
    if (usedChips.has(p.chipId) || usedLines.has(p.lineIndex)) continue;
    usedChips.add(p.chipId);
    usedLines.add(p.lineIndex);
    matches.push(p);
  }
  matches.sort((a, b) => a.lineIndex - b.lineIndex);
  const unmatchedLines = lines.flatMap((l, i) => (l.isTax || usedLines.has(i) ? [] : [i]));
  return { lines, matches, unmatchedLines };
}

/** Prices matched chips from the receipt (line plus pro rata tax) and sets chip states. Claims are kept. */
function priceFromReceipt(run: Run, receipt: ReceiptState): Run {
  const taxCents = receipt.lines.filter((l) => l.isTax).reduce((a, l) => a + l.cents, 0);
  const lineCents = receipt.matches.map((m) => receipt.lines[m.lineIndex].cents);
  const tax = allocateTax(lineCents, taxCents);
  const priceByChip = new Map<string, number>();
  receipt.matches.forEach((m, i) => priceByChip.set(m.chipId, lineCents[i] + tax[i]));
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
  if (!run.chips.some((c) => c.id === target.chipId)) return run;
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
