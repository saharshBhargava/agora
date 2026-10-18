import { fireEvent, render, screen } from '@testing-library/react';
import { expect, test, vi } from 'vitest';
import { Board } from '@/components/Board';
import type { Chip as ChipT, Person } from '@/lib/types';

const p = (id: string): Person => ({ id, name: id.toUpperCase(), initial: id.toUpperCase(), isShopper: false, authorizedCents: 4000, authId: null, payoutPan: null });
const people = [p('a'), p('b')];
const mk = (o: Partial<ChipT>): ChipT => ({
  id: 'c', name: 'Item', priceCents: 100, priceSource: 'sticker', photoUrl: null, region: null, quantity: 1,
  claimers: [], state: 'open', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
  overCap: [], removedAt: null, addedAt: 0, ...o,
});
const setup = (chips: ChipT[], auth = 4000) => {
  const h = { onClaim: vi.fn(), onLeave: vi.fn(), onOverCap: vi.fn() };
  render(<Board chips={chips} people={people} me="a" authorizedCents={auth} taxRate={0} {...h} />);
  return h;
};

test('keyboard Enter claims through the toast path', () => {
  const h = setup([mk({ id: 'milk', name: 'Milk', priceCents: 429 })]);
  fireEvent.keyDown(screen.getByLabelText(/^Milk/), { key: 'Enter' });
  expect(h.onClaim).toHaveBeenCalledWith('milk');
  fireEvent.click(screen.getByRole('button', { name: 'Undo' }));
  expect(h.onLeave).toHaveBeenCalledWith('milk');
});

test('keyboard Enter over the cap calls onOverCap, no claim, no toast', () => {
  const big = mk({ id: 'big', name: 'Big', priceCents: 5000 });
  const h = setup([big]);
  fireEvent.keyDown(screen.getByLabelText(/^Big/), { key: 'Enter' });
  expect(h.onClaim).not.toHaveBeenCalled();
  expect(h.onOverCap).toHaveBeenCalledWith(big);
  expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
});

test('Enter on a tray chip leaves with an Undo that claims', () => {
  const eggs = mk({ id: 'eggs', name: 'Eggs', priceCents: 872, claimers: ['a'], state: 'claimed' });
  const h = setup([eggs]);
  const trayChip = screen.getAllByLabelText(/^Eggs, your share/)[0];
  fireEvent.keyDown(trayChip, { key: 'Enter' });
  expect(h.onLeave).toHaveBeenCalledWith('eggs');
  fireEvent.click(screen.getByRole('button', { name: 'Undo' }));
  expect(h.onClaim).toHaveBeenCalledWith('eggs');
});
