import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, expect, test, vi } from 'vitest';
import type { Chip, Run } from '@/lib/types';

const chip = (o: Partial<Chip> = {}): Chip => ({
  id: 'eggs', name: 'Eggs', priceCents: 872, priceSource: 'sticker', photoUrl: null, region: null, quantity: 1,
  claimers: [], state: 'open', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
  overCap: [], removedAt: null, addedAt: 0, ...o,
});
const run = (o: Partial<Run> = {}): Run => ({
  id: 'r1', state: 'open', store: 'Costco', shopperId: 'shop', taxRate: 0, lastCallEndsAt: null,
  receipt: null, settle: {}, payout: null,
  people: [
    { id: 'shop', name: 'Sam', initial: 'S', isShopper: true, authorizedCents: null, authId: null, approvalCode: null, payoutPan: null },
    { id: 'a', name: 'A', initial: 'A', isShopper: false, authorizedCents: 4000, authId: 'x', approvalCode: null, payoutPan: null },
  ],
  chips: [chip({ claimers: ['a'], overCap: ['a'] })],
  ...o,
});
const send = vi.fn(() => true);
let sock: Record<string, unknown>;
let search = 'run=r1&person=a';
vi.mock('@/lib/socket', () => ({ useRun: () => sock }));
const raise = vi.fn(async () => ({ authorizedCents: 6000 }));
vi.mock('@/lib/api', () => ({ api: { raise: (...a: unknown[]) => (raise as (...x: unknown[]) => unknown)(...a), wish: vi.fn(async () => ({})) } }));
const replace = vi.fn();
vi.mock('next/navigation', () => ({ useSearchParams: () => new URLSearchParams(search), useRouter: () => ({ replace, push: replace }) }));
let boardProps: { onOverCap?: (c: Chip) => void } = {};
vi.mock('@/components/Board', async (orig) => {
  const mod = await orig<typeof import('@/components/Board')>();
  return { Board: (p: Parameters<typeof mod.Board>[0]) => { boardProps = p; return mod.Board(p); } };
});

import { ApiError } from '@/lib/api-error';
import ClaimScreen from '@/app/claim/ClaimScreen';

const mk = (r: Run, extra: Record<string, unknown> = {}) => {
  sock = { run: r, send, connected: true, lastFrame: null, lastCallEndsAt: null, identifyingRegion: null, error: null, errorEvent: null, ...extra };
};
beforeEach(() => {
  send.mockClear(); raise.mockClear(); replace.mockClear();
  search = 'run=r1&person=a';
  mk(run());
});

test('tray chip shows the over-cap badge text when overCap includes me', () => {
  render(<ClaimScreen />);
  expect(screen.getByText('Raise your cap or leave')).toBeInTheDocument();
});

test('redirects to /join when the person param is missing', () => {
  search = 'run=r1';
  render(<ClaimScreen />);
  expect(replace).toHaveBeenCalledWith('/join?run=r1');
});

test('redirects to /join when the person is not in the run', () => {
  search = 'run=r1&person=zzz';
  render(<ClaimScreen />);
  expect(replace).toHaveBeenCalledWith('/join?run=r1');
});

test('over-cap drop shows the toast; Raise to $60.00 posts cap + $20', async () => {
  render(<ClaimScreen />);
  act(() => boardProps.onOverCap?.(chip({ id: 'towels', name: 'Towels' })));
  expect(screen.getByText('Over your cap. Raise it?')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Raise to $60.00' }));
  await waitFor(() => expect(raise).toHaveBeenCalledWith('r1', 'a', 6000));
});

test('a 403 from raise hides the action and says it is off', async () => {
  raise.mockRejectedValueOnce(new ApiError('raise off', 403));
  render(<ClaimScreen />);
  act(() => boardProps.onOverCap?.(chip({ id: 'towels', name: 'Towels' })));
  fireEvent.click(screen.getByRole('button', { name: 'Raise to $60.00' }));
  expect(await screen.findByText('Raising your cap is off for this run')).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: /Raise to/ })).toBeNull();
});

test('locked banner states the tray total', () => {
  mk(run({ state: 'locked', chips: [chip({ claimers: ['a'] })] }));
  render(<ClaimScreen />);
  expect(screen.getByText('Your tray is $8.72 across 1 item')).toBeInTheDocument();
});

test('errorEvent shows a transient toast', () => {
  mk(run(), { errorEvent: { reason: 'cart closed', seq: 1 } });
  render(<ClaimScreen />);
  expect(screen.getByText('cart closed')).toBeInTheDocument();
});

test('the header keeps the held amount and approval code visible', () => {
  const r = run();
  mk({ ...r, people: r.people.map((p) => (p.id === 'a' ? { ...p, approvalCode: '888888' } : p)) });
  render(<ClaimScreen />);
  expect(screen.getByText('$40.00 held · approval 888888')).toBeInTheDocument();
});

test('the last-call banner shows the countdown', () => {
  vi.useFakeTimers();
  try {
    const endsAt = Date.now() + 5000;
    mk(run({ state: 'lastCall', lastCallEndsAt: endsAt }), { lastCallEndsAt: endsAt });
    render(<ClaimScreen />);
    expect(screen.getByText('Sam is checking out · last call · 5s')).toBeInTheDocument();
    act(() => { vi.advanceTimersByTime(2000); });
    expect(screen.getByText('Sam is checking out · last call · 3s')).toBeInTheDocument();
  } finally {
    vi.useRealTimers();
  }
});

test('an ended run says so instead of reconnecting', () => {
  mk(null as unknown as Run, { connected: false, ended: true });
  render(<ClaimScreen />);
  expect(screen.getByText('This run has ended')).toBeInTheDocument();
});
