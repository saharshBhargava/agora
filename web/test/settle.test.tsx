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
    { id: 'shop', name: 'Sam', initial: 'S', isShopper: true, authorizedCents: null, authId: null, approvalCode: null, payoutPan: null },
    { id: 'a', name: 'A', initial: 'A', isShopper: false, authorizedCents: 4000, authId: 'x', approvalCode: null, payoutPan: null },
    { id: 'b', name: 'B', initial: 'B', isShopper: false, authorizedCents: 4000, authId: 'y', approvalCode: null, payoutPan: null },
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

test('settled run renders a card per claimer and the shopper hero with exact copy', () => {
  mk(settled);
  render(<SettleScreen />);
  expect(screen.getByText('$35.64 released · settles tonight')).toBeInTheDocument();
  expect(screen.getByText('$11.65 released · settles tonight')).toBeInTheDocument();
  const cards = screen.getAllByRole('listitem').filter((li) => li.classList.contains('person-card'));
  expect(cards[0]).toHaveTextContent('Captured $4.36');
  expect(cards[0]).toHaveTextContent('auth 888888');
  expect(cards[1]).toHaveTextContent('Captured $28.35');
  expect(screen.getByText('Sam gets back')).toBeInTheDocument();
  expect(screen.getByText('$32.71')).toBeInTheDocument();
  expect(screen.getByText('Run settled · nobody chases anybody')).toBeInTheDocument();
  expect(screen.getByRole('link', { name: 'Start another run' })).toHaveAttribute('href', '/');
});

test('the hero names what stays with the shopper, or omits the sentence', () => {
  mk({ ...settled, chips: [chip('eggs', 'Eggs', { claimers: ['a'] }), chip('milk', 'Milk', { priceCents: 429, state: 'matched' })] });
  const { unmount } = render(<SettleScreen />);
  expect(screen.getByText("Pushed to Sam's card over Visa Direct (simulated in this build). Milk, $4.29, stays with Sam.")).toBeInTheDocument();
  unmount();
  mk({ ...settled, chips: [chip('eggs', 'Eggs', { claimers: ['a'] }), chip('milk', 'Milk', { putBack: true })] });
  render(<SettleScreen />);
  expect(screen.getByText("Pushed to Sam's card over Visa Direct (simulated in this build).")).toBeInTheDocument();
});

test('the settled receipt shows mono lines, a TOTAL and how many lines matched', () => {
  mk({
    ...settled,
    receipt: {
      lines: [{ text: 'KS EGGS 24CT', cents: 872, quantity: 1, isTax: false }, { text: '2% MILK', cents: 429, quantity: 1, isTax: false }],
      matches: [{ chipId: 'eggs', lineIndex: 0, confidence: 0.9 }, { chipId: 'milk', lineIndex: 1, confidence: 0.8 }],
      unmatchedLines: [],
    },
  });
  render(<SettleScreen />);
  expect(screen.getByText('2 of 2 lines matched')).toBeInTheDocument();
  expect(screen.getByText('TOTAL')).toBeInTheDocument();
  expect(screen.getByText('13.01')).toBeInTheDocument();
});

test('owed case', () => {
  mk(base({ settle: { a: ps({ capturedCents: 4000, owedCents: 112 }) } }));
  render(<SettleScreen />);
  expect(screen.getByText('Captured $40.00 · $1.12 owed')).toBeInTheDocument();
  expect(screen.getByText('$40.00')).toBeInTheDocument();
});

test('partlySettled shows the badge and Retry that confirms again', async () => {
  mk(base({ state: 'partlySettled', settle: { a: ps({ step: 'failed', error: 'x' }), b: ps({ capturedCents: 2835, releasedCents: 1165 }) } }));
  render(<SettleScreen />);
  expect(screen.getByText('Partly settled')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
  await waitFor(() => expect(api.confirm).toHaveBeenCalledWith('r1', 'shop'));
});

test('a claimer sees a plain note instead of a Retry button on failure', () => {
  search = 'run=r1&person=a';
  mk(base({ state: 'partlySettled', settle: { a: ps({ step: 'failed', error: 'x' }) } }));
  render(<SettleScreen />);
  expect(screen.getByText("Didn't go through, the shopper will retry")).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Retry' })).toBeNull();
});

test('Pair and Mine are disabled while a fix is in flight', async () => {
  let release!: () => void;
  api.fixReceiptLine.mockImplementationOnce(() => new Promise((r) => { release = () => r({}); }));
  mk(base({
    state: 'receipt',
    receipt: { lines: [{ text: 'MILK', cents: 429, quantity: 1, isTax: false }], matches: [], unmatchedLines: [0] },
  }));
  render(<SettleScreen />);
  fireEvent.click(screen.getByRole('button', { name: 'Mine' }));
  await waitFor(() => expect(screen.getByRole('button', { name: 'Mine' })).toBeDisabled());
  expect(screen.getByRole('button', { name: /Pair/ })).toBeDisabled();
  fireEvent.click(screen.getByRole('button', { name: 'Mine' }));
  expect(api.fixReceiptLine).toHaveBeenCalledTimes(1);
  release();
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

test('a $0 share shows nothing captured and the full release', () => {
  mk(base({ state: 'partlySettled', settle: { a: ps({ step: 'reversed', shareCents: 0, releasedCents: 4000, captureId: null }) } }));
  render(<SettleScreen />);
  expect(screen.getByText('Nothing captured · $40.00 released')).toBeInTheDocument();
  expect(screen.queryByText('Settling…')).toBeNull();
});
