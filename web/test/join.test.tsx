import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { beforeEach, expect, test, vi } from 'vitest';

// A plain function (not vi.fn) so a deliberately rejected join is not tracked as an unhandled rejection.
let impl: (...a: unknown[]) => Promise<unknown>;
let calls: unknown[][] = [];
vi.mock('@/lib/api', () => ({
  api: {
    join: (...a: unknown[]) => {
      calls.push(a);
      return impl(...a);
    },
    createRun: () => Promise.reject(new Error('unused')),
  },
  TEST_CARD: { number: '4111111111111111', expMonth: 12, expYear: 2031 },
}));
const params = new URLSearchParams('run=r1');
const push = vi.fn();
vi.mock('next/navigation', () => ({ useSearchParams: () => params, useRouter: () => ({ push, replace: push }) }));

import JoinScreen from '@/app/join/JoinScreen';

beforeEach(() => {
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
