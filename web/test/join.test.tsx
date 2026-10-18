import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { beforeEach, expect, test, vi } from 'vitest';

// A plain function (not vi.fn) so a deliberately rejected join is not tracked as an unhandled rejection.
let impl: (...a: unknown[]) => Promise<unknown>;
let calls: unknown[][] = [];
let runImpl: () => Promise<unknown> = () => Promise.reject(new Error('no run'));
vi.mock('@/lib/api', () => ({
  api: {
    join: (...a: unknown[]) => {
      calls.push(a);
      return impl(...a);
    },
    createRun: () => Promise.reject(new Error('unused')),
    getRun: () => runImpl(),
  },
  TEST_CARD: { number: '4111111111111111', expMonth: 12, expYear: 2031 },
}));
const params = new URLSearchParams('run=r1');
const push = vi.fn();
vi.mock('next/navigation', () => ({ useSearchParams: () => params, useRouter: () => ({ push, replace: push }) }));

import JoinScreen from '@/app/join/JoinScreen';

beforeEach(() => {
  runImpl = () => Promise.reject(new Error('no run'));
  calls = [];
  push.mockClear();
});

test('tapping Join shows the held badge with approval code', async () => {
  impl = async () => ({
    personId: 'p1',
    auth: { status: 'AUTHORIZED', authId: 'a1', approvalCode: '888888', authorizedCents: 4000 },
  });
  render(<JoinScreen />);
  fireEvent.click(screen.getByRole('button', { name: /join/i }));
  expect(await screen.findByText('$40.00 held · approval 888888')).toBeInTheDocument();
  expect(calls).toEqual([['r1', 'A', 4000, { decline: false }]]);
});

test('shows the server error when join is refused', async () => {
  impl = () => Promise.reject(new Error('run is locked'));
  render(<JoinScreen />);
  fireEvent.click(screen.getByRole('button', { name: /join/i }));
  await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('run is locked'));
});

test('after a successful join, Start claiming routes to /claim with the person id', async () => {
  impl = async () => ({
    personId: 'p1',
    auth: { status: 'AUTHORIZED', authId: 'a1', approvalCode: '888888', authorizedCents: 4000 },
  });
  render(<JoinScreen />);
  fireEvent.click(screen.getByRole('button', { name: /join/i }));
  // The held badge stays on screen until the claimer moves on.
  expect(await screen.findByText('$40.00 held · approval 888888')).toBeInTheDocument();
  await new Promise((r) => setTimeout(r, 20));
  expect(push).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Start claiming' }));
  expect(push).toHaveBeenCalledWith('/claim?run=r1&person=p1');
});

const person = (id: string, name: string, isShopper = false) => ({
  id, name, initial: name[0], isShopper, authorizedCents: isShopper ? null : 4000, authId: null, approvalCode: null, payoutPan: null,
});
const chipOf = (id: string, name: string, o: object = {}) => ({
  id, name, priceCents: 872, priceSource: 'sticker', photoUrl: null, region: null, quantity: 1, claimers: [], state: 'open',
  wishedBy: null, duplicateOf: null, putBack: false, dropped: false, overCap: [], removedAt: null, addedAt: 0, ...o,
});

test('the run card is titled from the run and shows who is in and what is in the cart', async () => {
  runImpl = async () => ({
    id: 'r1', state: 'open', store: 'costco', shopperId: 'j', taxRate: 0, lastCallEndsAt: null, receipt: null, settle: {}, payout: null,
    people: [person('j', 'Jake', true), person('m', 'Marcus')],
    chips: [chipOf('e', 'Eggs', { addedAt: 1 }), chipOf('t', 'Towels', { addedAt: 2 }), chipOf('k', 'Milk', { addedAt: 3 }), chipOf('x', 'Soap', { addedAt: 4 }), chipOf('w', 'Bagels', { state: 'wish', addedAt: 5 })],
  });
  render(<JoinScreen />);
  expect(await screen.findByRole('heading', { name: "Jake's Costco run" })).toBeInTheDocument();
  expect(screen.getByText('Invited by Jake')).toBeInTheDocument();
  expect(screen.getByText('Jake is shopping · Marcus is in')).toBeInTheDocument();
  // Up to three live chips, newest first; never a wish.
  expect(screen.getAllByRole('listitem').map((t) => t.getAttribute('aria-label'))).toEqual(['Soap', 'Milk', 'Towels']);
  expect(screen.getByRole('button', { name: "Join Jake's run" })).toBeInTheDocument();
  expect(screen.getByText('$40')).toBeInTheDocument();
  expect(screen.getByText('Visa ending 1111')).toBeInTheDocument();
});

test('with no chips yet the cart tiles are left out', async () => {
  runImpl = async () => ({
    id: 'r1', state: 'open', store: 'costco', shopperId: 'j', taxRate: 0, lastCallEndsAt: null, receipt: null, settle: {}, payout: null,
    people: [person('j', 'Jake', true)], chips: [],
  });
  render(<JoinScreen />);
  await screen.findByRole('heading', { name: "Jake's Costco run" });
  expect(screen.queryByText('In the cart so far')).toBeNull();
});
