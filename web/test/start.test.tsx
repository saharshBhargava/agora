import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import type { Run } from '@/lib/types';

let search = '';
const push = vi.fn();
const replace = vi.fn();
vi.mock('next/navigation', () => ({ useSearchParams: () => new URLSearchParams(search), useRouter: () => ({ push, replace }) }));
const createRun = vi.fn(async () => ({ runId: 'r1', shopperId: 'jake' }));
vi.mock('@/lib/api', () => ({ api: { createRun: () => createRun() } }));
let sockRun: Run | null = null;
vi.mock('@/lib/socket', () => ({ useRun: () => ({ run: sockRun, connected: true }) }));

import StartScreen from '@/app/StartScreen';

const person = (id: string, name: string, o: object = {}) => ({
  id, name, initial: name[0], isShopper: false, authorizedCents: 4000, authId: 'a', approvalCode: '888888', payoutPan: null, ...o,
});
const run = (people: ReturnType<typeof person>[]): Run => ({
  id: 'r1', state: 'open', store: 'costco', shopperId: 'jake', taxRate: 0, lastCallEndsAt: null, receipt: null, settle: {}, payout: null,
  people: [person('jake', 'Jake', { isShopper: true, authorizedCents: null }), ...people], chips: [],
});

beforeEach(() => {
  search = '';
  push.mockClear();
  replace.mockClear();
  sockRun = null;
});
afterEach(() => vi.unstubAllGlobals());

test('Start a run creates the run and opens the invite for it', async () => {
  render(<StartScreen />);
  fireEvent.click(screen.getByRole('button', { name: 'Start a run' }));
  await waitFor(() => expect(replace).toHaveBeenCalledWith('/?run=r1&person=jake'));
});

test('the invite shows the QR for the run and the people who joined with their hold', () => {
  search = 'run=r1&person=jake';
  sockRun = run([person('m', 'Marcus')]);
  render(<StartScreen />);
  expect(screen.getByRole('heading', { name: 'Your Costco run is open' })).toBeInTheDocument();
  expect(screen.getByRole('img', { name: 'QR code to join the run' })).toHaveAttribute('src', '/api/runs/r1/qr');
  expect(screen.getByText('Next to you? Scan to join')).toBeInTheDocument();
  expect(screen.getByText('Marcus')).toBeInTheDocument();
  expect(screen.getByText('$40 held')).toBeInTheDocument();
  expect(screen.getByText('Waiting for more…')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Clip phone to cart and start' }));
  expect(push).toHaveBeenCalledWith('/shopper?run=r1&person=jake');
});

test('without a share sheet, Send link copies the join link and says so', async () => {
  search = 'run=r1&person=jake';
  sockRun = run([]);
  const writeText = vi.fn(async () => undefined);
  Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true });
  Object.defineProperty(navigator, 'share', { value: undefined, configurable: true });
  render(<StartScreen />);
  await act(async () => {
    fireEvent.click(screen.getByRole('button', { name: 'Send link to the house chat' }));
  });
  expect(writeText).toHaveBeenCalledWith(`${window.location.origin}/join?run=r1`);
  expect(screen.getByText('Link copied')).toBeInTheDocument();
});

test('with a share sheet, Send link shares the join link', async () => {
  search = 'run=r1&person=jake';
  sockRun = run([]);
  const share = vi.fn(async () => undefined);
  Object.defineProperty(navigator, 'share', { value: share, configurable: true });
  render(<StartScreen />);
  await act(async () => {
    fireEvent.click(screen.getByRole('button', { name: 'Send link to the house chat' }));
  });
  expect(share).toHaveBeenCalledWith(expect.objectContaining({ url: `${window.location.origin}/join?run=r1` }));
  expect(screen.queryByText('Link copied')).toBeNull();
  Object.defineProperty(navigator, 'share', { value: undefined, configurable: true });
});
