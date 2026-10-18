import { describe, expect, it } from 'vitest';
import { addChip, checkout, claim, createRun, join, lock, putBack, setAuthorization } from '../src/run.js';
import { applyReceipt, fixReceiptLine, matchReceipt, parseReceiptLines, settle } from '../src/settle.js';
import { SimPayments } from '../src/payments/sim.js';
import type { PaymentsProvider } from '../src/payments/provider.js';
import type { Chip, Run } from '../src/types.js';

type Err = { error: string };
const ok = (r: Run | Err): Run => {
  if ('error' in r) throw new Error(`unexpected error: ${r.error}`);
  return r;
};
const chip = (id: string, name: string, priceCents: number | null) => ({
  id, name, priceCents, priceSource: priceCents === null ? ('none' as const) : ('sticker' as const),
  photoUrl: null, region: null, quantity: 1,
});
const get = (run: Run, id: string): Chip => run.chips.find((c) => c.id === id)!;
const person = (id: string, authorizedCents = 4000) => ({
  id, name: id, initial: id.toUpperCase(), isShopper: false, authorizedCents, authId: `auth-${id}`, approvalCode: '888888', payoutPan: null,
});

/** a and b split eggs; b also takes towels. Locked, ready for a receipt. */
function lockedRun(eggsCents = 872): Run {
  let r = createRun({ id: 's', name: 'Sam', initial: 'S', payoutPan: null }, 'Costco', '4111111111111111', 0);
  r = ok(join(r, person('a')));
  r = ok(join(r, person('b')));
  r = setAuthorization(r, 'a', 4000, 'auth-a');
  r = setAuthorization(r, 'b', 4000, 'auth-b');
  r = addChip(r, chip('eggs', 'Kirkland Eggs 24 ct', eggsCents), 0);
  r = addChip(r, chip('towels', 'Paper Towels 12 pk', 2399), 100);
  r = addChip(r, chip('milk', '2% Milk', 429), 200);
  r = ok(claim(r, 'eggs', 'a', 1));
  r = ok(claim(r, 'eggs', 'b', 2));
  r = ok(claim(r, 'towels', 'b', 3));
  r = checkout(r, 1000, 0);
  return lock(r, 1000);
}

const rawLines = [
  { text: 'KS EGGS 24CT', cents: 872, quantity: 1 },
  { text: 'PAPER TOWEL 12PK', cents: 2399, quantity: 1 },
  { text: '2% MILK', cents: 429, quantity: 1 },
  { text: 'BANANAS', cents: 199, quantity: 1 },
];

describe('parseReceiptLines', () => {
  it('marks tax lines', () => {
    const lines = parseReceiptLines([...rawLines, { text: 'SALES TAX', cents: 50, quantity: 1 }]);
    expect(lines.map((l) => l.isTax)).toEqual([false, false, false, false, true]);
  });
});

describe('matchReceipt', () => {
  it('maps lines to chips and leaves extras unmatched', () => {
    const m = matchReceipt(lockedRun(), parseReceiptLines(rawLines));
    const byChip = Object.fromEntries(m.matches.map((x) => [x.chipId, x]));
    expect(byChip.eggs.lineIndex).toBe(0);
    expect(byChip.eggs.confidence).toBeGreaterThanOrEqual(0.5);
    expect(byChip.towels.lineIndex).toBe(1);
    expect(byChip.milk.lineIndex).toBe(2);
    expect(m.unmatchedLines).toEqual([3]);
  });
  it('leaves the line of a put-back chip unmatched', () => {
    const m = matchReceipt(putBack(lockedRun(), 'milk'), parseReceiptLines(rawLines));
    expect(m.matches.some((x) => x.chipId === 'milk')).toBe(false);
    expect(m.unmatchedLines).toEqual([2, 3]);
  });
  it('never matches tax lines', () => {
    const m = matchReceipt(lockedRun(), parseReceiptLines([{ text: 'TAX', cents: 10, quantity: 1 }]));
    expect(m.matches).toEqual([]);
    expect(m.unmatchedLines).toEqual([]);
  });
});

describe('applyReceipt', () => {
  it('replaces the sticker price with the receipt price and keeps claims', () => {
    const run = lockedRun(850);
    const out = applyReceipt(run, matchReceipt(run, parseReceiptLines(rawLines)));
    expect(get(out, 'eggs')).toMatchObject({ priceCents: 872, priceSource: 'receipt', state: 'matched', claimers: ['a', 'b'] });
    expect(out.state).toBe('receipt');
    expect(out.receipt).not.toBeNull();
  });
  it('allocates tax across matched lines', () => {
    const run = lockedRun();
    const lines = parseReceiptLines([
      { text: 'EGGS', cents: 800, quantity: 1 },
      { text: 'TOWELS', cents: 2200, quantity: 1 },
      { text: 'TAX', cents: 271, quantity: 1 },
    ]);
    const out = applyReceipt(run, matchReceipt(run, lines));
    expect(get(out, 'eggs').priceCents).toBe(872);
    expect(get(out, 'towels').priceCents).toBe(2399);
  });
  it('marks chips without a line unmatched, keeping claims', () => {
    const run = lockedRun();
    const lines = parseReceiptLines([{ text: 'KS EGGS 24CT', cents: 872, quantity: 1 }]);
    const out = applyReceipt(run, matchReceipt(run, lines));
    expect(get(out, 'towels')).toMatchObject({ state: 'unmatched', claimers: ['b'] });
  });
});

describe('fixReceiptLine', () => {
  it('pairs an unmatched line to a chip', () => {
    const run = lockedRun();
    const lines = parseReceiptLines([rawLines[0], rawLines[1], rawLines[3]]);
    let out = applyReceipt(run, matchReceipt(run, lines));
    expect(out.receipt!.unmatchedLines).toEqual([2]);
    expect(get(out, 'milk').state).toBe('unmatched');
    out = fixReceiptLine(out, 2, { chipId: 'milk' });
    expect(out.receipt!.unmatchedLines).toEqual([]);
    expect(out.receipt!.matches.find((m) => m.lineIndex === 2)!.chipId).toBe('milk');
    expect(get(out, 'milk')).toMatchObject({ state: 'matched', priceCents: 199, priceSource: 'receipt' });
  });
  it("'mine' removes the line from unmatched", () => {
    const run = lockedRun();
    let out = applyReceipt(run, matchReceipt(run, parseReceiptLines(rawLines)));
    out = fixReceiptLine(out, 3, 'mine');
    expect(out.receipt!.unmatchedLines).toEqual([]);
    expect(out.receipt!.mine).toEqual([3]);
  });
});

type Call = [string, ...unknown[]];
function recorder(opts: { throwOn?: (c: Call) => boolean; declineIncremental?: boolean } = {}) {
  const calls: Call[] = [];
  const p: PaymentsProvider = {
    async authorize() { throw new Error('unused'); },
    async incremental(ref, authId, delta) {
      calls.push(['incremental', authId, delta]);
      return opts.declineIncremental
        ? { status: 'DECLINED', authId, approvalCode: '', authorizedCents: 0 }
        : { status: 'AUTHORIZED', authId, approvalCode: '888888', authorizedCents: 2000 + delta };
    },
    async reverse(ref, authId, amt) {
      const c: Call = ['reverse', authId, amt];
      if (opts.throwOn?.(c)) throw new Error('boom');
      calls.push(c);
      return { status: 'REVERSED', reversedCents: amt };
    },
    async capture(ref, authId, amt) {
      calls.push(['capture', authId, amt]);
      return { status: 'PENDING', captureId: `cap-${authId}` };
    },
    async payout(ref, pan, amt) {
      calls.push(['payout', pan, amt]);
      return { simulated: true, businessApplicationId: 'FD', amountCents: amt, recipientPan: pan, requestId: 'req' };
    },
  };
  return { p, calls };
}
const refFn = (run: Run) => (id: string, step: string) => `${run.id}-${id}-${step}`;
const received = (run: Run) => applyReceipt(run, matchReceipt(run, parseReceiptLines(rawLines)));

describe('settle', () => {
  it('reverses the unused part, captures each share, then pays out', async () => {
    const run = received(lockedRun());
    const { p, calls } = recorder();
    const persisted: Run[] = [];
    const out = await settle(run, p, refFn(run), async (r) => { persisted.push(r); });
    expect(calls).toEqual([
      ['reverse', 'auth-a', 3564], ['capture', 'auth-a', 436],
      ['reverse', 'auth-b', 1165], ['capture', 'auth-b', 2835],
      ['payout', '4111111111111111', 3271],
    ]);
    expect(out.state).toBe('settled');
    expect(out.settle.a).toMatchObject({ step: 'captured', capturedCents: 436, releasedCents: 3564, owedCents: 0 });
    expect(out.settle.b).toMatchObject({ step: 'captured', capturedCents: 2835, captureId: 'cap-auth-b' });
    expect(out.payout?.amountCents).toBe(3271);
    expect(persisted.length).toBeGreaterThan(4);
    expect(out.settle.a.approvalCode).toBe('888888');
    expect(out.settle.b.approvalCode).toBe('888888');
  });
  it('releases claims on unmatched chips before computing shares', async () => {
    const lockedR = lockedRun();
    const lines = parseReceiptLines([{ text: 'KS EGGS 24CT', cents: 872, quantity: 1 }]);
    const run = applyReceipt(lockedR, matchReceipt(lockedR, lines));
    const { p, calls } = recorder();
    const out = await settle(run, p, refFn(run), async () => {});
    expect(get(out, 'towels').claimers).toEqual([]);
    expect(calls.filter((c) => c[0] === 'capture')).toEqual([['capture', 'auth-a', 436], ['capture', 'auth-b', 436]]);
    expect(out.settle.b.releasedCents).toBe(3564);
  });
  it('reverses everything for a person with no share and is terminal', async () => {
    let run = lockedRun();
    run = ok(join({ ...run, state: 'open' }, person('c')));
    run = setAuthorization(run, 'c', 1000, 'auth-c');
    run = received(run);
    const { p, calls } = recorder();
    const out = await settle(run, p, refFn(run), async () => {});
    expect(calls).toContainEqual(['reverse', 'auth-c', 1000]);
    expect(calls.some((c) => c[0] === 'capture' && c[1] === 'auth-c')).toBe(false);
    expect(out.settle.c).toMatchObject({ step: 'reversed', shareCents: 0, releasedCents: 1000 });
    expect(out.state).toBe('settled');
  });
  it('increments first when the share is above the authorization', async () => {
    let run = lockedRun();
    run = setAuthorization(run, 'b', 2000, 'auth-b'); // share 2835 > 2000
    run = received(run);
    const { p, calls } = recorder();
    const out = await settle(run, p, refFn(run), async () => {});
    const bCalls = calls.filter((c) => c[1] === 'auth-b');
    expect(bCalls[0]).toEqual(['incremental', 'auth-b', 835]);
    expect(out.settle.b.step).toBe('captured');
  });
  it('captures the authorized amount and records owed when incremental is declined', async () => {
    let run = lockedRun();
    run = setAuthorization(run, 'b', 2000, 'auth-b');
    run = received(run);
    const { p, calls } = recorder({ declineIncremental: true });
    const out = await settle(run, p, refFn(run), async () => {});
    expect(calls).toContainEqual(['capture', 'auth-b', 2000]);
    expect(calls.some((c) => c[0] === 'reverse' && c[1] === 'auth-b')).toBe(false);
    expect(out.settle.b).toMatchObject({ capturedCents: 2000, owedCents: 835 });
    expect(out.state).toBe('partlySettled');
    expect(out.payout?.amountCents).toBe(436 + 2000);
  });
  it('resumes after a failure without repeating completed calls', async () => {
    const run = received(lockedRun());
    const bad = recorder({ throwOn: (c) => c[1] === 'auth-b' && c[0] === 'reverse' });
    let stored: Run = run;
    const first = await settle(run, bad.p, refFn(run), async (r) => { stored = r; });
    expect(first.state).toBe('partlySettled');
    expect(first.settle.a.step).toBe('captured');
    expect(first.settle.b).toMatchObject({ step: 'failed', error: 'boom' });
    expect(first.payout).toBeNull();
    expect(stored).toEqual(first);
    const good = recorder();
    const second = await settle(first, good.p, refFn(run), async () => {});
    expect(good.calls).toEqual([
      ['reverse', 'auth-b', 1165], ['capture', 'auth-b', 2835], ['payout', '4111111111111111', 3271],
    ]);
    expect(second.state).toBe('settled');
  });
  it('does not repeat a reverse when only the capture failed', async () => {
    const run = received(lockedRun());
    const calls: string[] = [];
    const sim = new SimPayments();
    const flaky: PaymentsProvider = {
      authorize: sim.authorize.bind(sim), incremental: sim.incremental.bind(sim),
      reverse: async (...a) => { calls.push('reverse'); throw new Error('unreached'); },
      capture: async () => { calls.push('capture'); throw new Error('capture down'); },
      payout: sim.payout.bind(sim),
    };
    // reverse works, capture throws
    flaky.reverse = async (ref, id, amt) => { calls.push(`reverse${amt}`); return { status: 'REVERSED', reversedCents: amt }; };
    const first = await settle(run, flaky, refFn(run), async () => {});
    expect(first.settle.a).toMatchObject({ step: 'failed', releasedCents: 3564 });
    const good = recorder();
    await settle(first, good.p, refFn(run), async () => {});
    expect(good.calls.slice(0, 2)).toEqual([['capture', 'auth-a', 436], ['capture', 'auth-b', 2835]]);
  });
  it('passes refs of the form run-person-step', async () => {
    const run = received(lockedRun());
    const refs: string[] = [];
    await settle(run, recorder().p, (id, step) => { refs.push(`${id}-${step}`); return `${run.id}-${id}-${step}`; }, async () => {});
    expect(refs).toContain('s-payout');
    expect(refs).toContain('a-reverse');
    expect(refs).toContain('a-capture');
  });
});
