import { render, screen } from '@testing-library/react';
import { expect, test } from 'vitest';
import { Chip } from '@/components/Chip';
import type { Chip as ChipT, Person } from '@/lib/types';

const p = (id: string, initial: string): Person => ({
  id, name: initial, initial, isShopper: false, authorizedCents: 4000, authId: null, payoutPan: null,
});
const people = [p('a', 'A'), p('b', 'B')];
const base: ChipT = {
  id: 'c1', name: 'Kirkland Eggs 24 ct', priceCents: 872, priceSource: 'sticker', photoUrl: null, region: null,
  quantity: 1, claimers: [], state: 'open', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
  overCap: [], removedAt: null, addedAt: 0,
};

test('quantity 2 shows x2', () => {
  render(<Chip chip={{ ...base, quantity: 2 }} me="a" people={people} />);
  expect(screen.getByText('×2')).toBeTruthy();
});

test('null price shows ~$?', () => {
  render(<Chip chip={{ ...base, priceCents: null }} me="a" people={people} />);
  expect(screen.getByText('~$?')).toBeTruthy();
});

test('wish is grey with the wisher initial and is not liftable', () => {
  const { container } = render(
    <Chip chip={{ ...base, state: 'wish', wishedBy: 'b', priceCents: null }} me="a" people={people} />,
  );
  const el = container.querySelector('[data-wish]')!;
  expect(el).not.toBeNull();
  expect(el.textContent).toContain('B');
  expect(container.querySelector('[data-liftable="true"]')).toBeNull();
});

test('over-cap badge shows when me is in overCap', () => {
  render(<Chip chip={{ ...base, overCap: ['a'] }} me="a" people={people} />);
  expect(screen.getByText('Over cap')).toBeTruthy();
});

test('no over-cap badge for someone else', () => {
  render(<Chip chip={{ ...base, overCap: ['b'] }} me="a" people={people} />);
  expect(screen.queryByText('Over cap')).toBeNull();
});

test('you are in fill and aria label', () => {
  const { container } = render(<Chip chip={{ ...base, claimers: ['a', 'b'], state: 'claimed' }} me="a" people={people} />);
  expect(container.querySelector('[data-mine]')).not.toBeNull();
  expect(screen.getByLabelText('Kirkland Eggs 24 ct, $8.72, claimed by A and B')).toBeTruthy();
});

test('identifying chip is dimmed and not liftable', () => {
  const { container } = render(<Chip chip={{ ...base, state: 'identifying' }} me="a" people={people} />);
  expect(container.querySelector('[data-identifying]')).not.toBeNull();
  expect(container.querySelector('[data-liftable="true"]')).toBeNull();
});
