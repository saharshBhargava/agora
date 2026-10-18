import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, expect, test, vi } from 'vitest';
import type { Chip, PersonSettle, Run } from '@/lib/types';

const chip = (id: string, name: string, o: Partial<Chip> = {}): Chip => ({
  id, name, priceCents: 872, priceSource: 'receipt', photoUrl: null, region: null, quantity: 1,
  claimers: [], state: 'matched', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
  overCap: [], removedAt: null, addedAt: 0, ...o,
});
const ps = (o: Partial<PersonSettle>): PersonSettle => ({
  step: 'captured', shareCents: 0, capturedCents: 0, releasedCents: 0, owedCents: 0, approvalCode: '888888', captureId: 'c', error: null, ...o,
});
const base = (o: Partial<Run> = {}): Run => ({
  id: 'r1', state: 'settled', store: 'Costco', shopperId: 'shop', taxRate: 0, lastCallEndsAt: null,
  receipt: null, settle: {}, payout: null,
  people: [
    { id: 'shop', name: 'Sam', initial: 'S', isShopper: true, authorizedCents: null, authId: null, payoutPan: null },
    { id: 'a', name: 'A', initial: 'A', isShopper: false, authorizedCents: 4000, authId: 'x', payoutPan: null },
    { id: 'b', name: 'B', initial: 'B', isShopper: false, authorizedCents: 4000, authId: 'y', payoutPan: null },
  ],
  chips: [chip('eggs', 'Eggs'), chip('milk', 'Milk', { state: 'unmatched' })],
  ...o,
});
let sock: Record<string, unknown>;
let search = 'run=r1&person=shop';
vi.mock('@/lib/socket', () => ({ useRun: () => sock }));
const api = {
  receipt: vi.fn(async () => ({})), confirm: vi.fn(async () => ({})), fixReceiptLine: vi.fn(async () => ({})),
};
vi.mock('@/lib/api', () => ({ api: { receipt: (...a: unknown[]) => (api.receipt as (...x: unknown[]) => unknown)(...a), confirm: (...a: unknown[]) => (api.confirm as (...x: unknown[]) => unknown)(...a), fixReceiptLine: (...a: unknown[]) => (api.fixReceiptLine as (...x: unknown[]) => unknown)(...a) } }));
vi.mock('next/navigation', () => ({ useSearchParams: () => new URLSearchParams(search) }));
vi.mock('@/components/Camera', () => ({ Camera: () => <div>camera</div> }));

import SettleScreen from '@/app/settle/SettleScreen';

const mk = (r: Run) => {
  sock = { run: r, send: vi.fn(() => true), connected: true, lastFrame: null, lastCallEndsAt: null, identifyingRegion: null, error: null, errorEvent: null };
};
beforeEach(() => { Object.values(api).forEach((f) => f.mockClear()); search = 'run=r1&person=shop'; });

const settled = base({
  settle: {
    a: ps({ shareCents: 436, capturedCents: 436, releasedCents: 3564 }),
    b: ps({ shareCents: 2835, capturedCents: 2835, releasedCents: 1165 }),
  },
  payout: { simulated: true, businessApplicationId: 'FD', amountCents: 3271, recipientPan: '4', requestId: 'q' },
});

test('settled run renders the three lines with exact copy', () => {
  mk(settled);
  render(<SettleScreen />);
  expect(screen.getByText('Captured $4.36 (settles tonight) · $35.64 released · approval 888888')).toBeInTheDocument();
  expect(screen.getByText('Captured $28.35 (settles tonight) · $11.65 released · approval 888888')).toBeInTheDocument();
  expect(screen.getByText('Reimbursed $32.71 (simulated Visa Direct)')).toBeInTheDocument();
});

test('owed case', () => {
  mk(base({ settle: { a: ps({ capturedCents: 4000, owedCents: 112 }) } }));
  render(<SettleScreen />);
  expect(screen.getByText('Captured $40.00 · $1.12 owed')).toBeInTheDocument();
});

test('partlySettled shows the badge and Retry that confirms again', async () => {
  mk(base({ state: 'partlySettled', settle: { a: ps({ step: 'failed', error: 'x' }), b: ps({ capturedCents: 2835, releasedCents: 1165 }) } }));
  render(<SettleScreen />);
  expect(screen.getByText('Partly settled')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
  await waitFor(() => expect(api.confirm).toHaveBeenCalledWith('r1', 'shop'));
});

test('claimer sees the settle page read-only', () => {
  search = 'run=r1&person=a';
  mk(base({
    state: 'receipt',
    receipt: { lines: [{ text: 'EGGS', cents: 872, quantity: 1, isTax: false }, { text: 'MILK', cents: 429, quantity: 1, isTax: false }], matches: [{ chipId: 'eggs', lineIndex: 0, confidence: 0.9 }], unmatchedLines: [1] },
  }));
  render(<SettleScreen />);
  expect(screen.getByText('EGGS')).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Confirm & charge' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Mine' })).toBeNull();
  expect(screen.queryByRole('button', { name: /Pair/ })).toBeNull();
});

test('shopper at receipt can mark Mine and Confirm & charge', async () => {
  mk(base({
    state: 'receipt',
    receipt: { lines: [{ text: 'EGGS', cents: 872, quantity: 1, isTax: false }, { text: 'MILK', cents: 429, quantity: 1, isTax: false }], matches: [{ chipId: 'eggs', lineIndex: 0, confidence: 0.9 }], unmatchedLines: [1] },
  }));
  render(<SettleScreen />);
  fireEvent.click(screen.getByRole('button', { name: 'Mine' }));
  await waitFor(() => expect(api.fixReceiptLine).toHaveBeenCalledWith('r1', 1, 'mine'));
  fireEvent.click(screen.getByRole('button', { name: 'Confirm & charge' }));
  await waitFor(() => expect(api.confirm).toHaveBeenCalledWith('r1', 'shop'));
});

test('mock=1 at locked offers Use printed receipt, posting an empty image', async () => {
  search = 'run=r1&person=shop&mock=1';
  mk(base({ state: 'locked' }));
  render(<SettleScreen />);
  fireEvent.click(screen.getByRole('button', { name: 'Use printed receipt' }));
  await waitFor(() => expect(api.receipt).toHaveBeenCalledWith('r1', ''));
});
