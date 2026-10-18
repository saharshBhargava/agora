import { act, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import type { Chip as ChipT, Person } from '@/lib/types';

type Monitor = {
  onDragStart?: (e: unknown) => void;
  onDragEnd?: (e: unknown) => void;
  onDragCancel?: (e: unknown) => void;
};
let monitor: Monitor = {};
vi.mock('@dnd-kit/core', async (orig) => {
  const m = await orig<typeof import('@dnd-kit/core')>();
  return { ...m, useDndMonitor: (l: Monitor) => { monitor = l; } };
});

import { Tray } from '@/components/Tray';
import { Grid } from '@/components/Grid';

const p = (id: string, initial: string): Person => ({
  id, name: initial, initial, isShopper: false, authorizedCents: 4000, authId: null, payoutPan: null,
});
const people = [p('a', 'A'), p('b', 'B')];
const mk = (o: Partial<ChipT>): ChipT => ({
  id: 'c', name: 'Item', priceCents: 100, priceSource: 'sticker', photoUrl: null, region: null, quantity: 1,
  claimers: [], state: 'open', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
  overCap: [], removedAt: null, addedAt: 0, ...o,
});
const eggs = mk({ id: 'eggs', name: 'Eggs', priceCents: 872, claimers: ['a', 'b'], state: 'claimed' });
const unknown = mk({ id: 'unk', name: 'Mystery', priceCents: null, claimers: ['a'], state: 'claimed' });

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

test('header shows held, share and room for eggs shared by two', () => {
  render(<Tray chips={[eggs]} me="a" people={people} authorizedCents={4000} taxRate={0} onClaim={vi.fn()} onLeave={vi.fn()} />);
  expect(screen.getByText('$40.00 held · $4.36 your share · $31.28 room')).toBeTruthy();
  expect(screen.getByText('1 item · $4.36')).toBeTruthy();
});

test('a ~$? chip counts $0', () => {
  render(<Tray chips={[eggs, unknown]} me="a" people={people} authorizedCents={4000} taxRate={0} onClaim={vi.fn()} onLeave={vi.fn()} />);
  expect(screen.getByText('$40.00 held · $4.36 your share · $31.28 room')).toBeTruthy();
});

test('shopper mode shows only items and total', () => {
  render(<Tray chips={[eggs]} me="a" people={people} authorizedCents={null} taxRate={0} onClaim={vi.fn()} onLeave={vi.fn()} />);
  expect(screen.getByText('1 item · $4.36')).toBeTruthy();
  expect(screen.queryByText(/held/)).toBeNull();
});

test('a claim drop calls onClaim and renders an Undo toast whose action leaves', () => {
  const onClaim = vi.fn();
  const onLeave = vi.fn();
  const milk = mk({ id: 'milk', name: 'Milk', priceCents: 429 });
  render(<Tray chips={[]} me="a" people={people} authorizedCents={4000} taxRate={0} onClaim={onClaim} onLeave={onLeave} />);
  act(() => monitor.onDragEnd!({ active: { id: 'milk', data: { current: { chip: milk, from: 'grid' } } }, over: { id: 'tray' } }));
  expect(onClaim).toHaveBeenCalledWith('milk');
  fireEvent.click(screen.getByRole('button', { name: 'Undo' }));
  expect(onLeave).toHaveBeenCalledWith('milk');
});

test('toast dismisses after 3 seconds', () => {
  const milk = mk({ id: 'milk', name: 'Milk', priceCents: 429 });
  render(<Tray chips={[]} me="a" people={people} authorizedCents={4000} taxRate={0} onClaim={vi.fn()} onLeave={vi.fn()} />);
  act(() => monitor.onDragEnd!({ active: { id: 'milk', data: { current: { chip: milk, from: 'grid' } } }, over: { id: 'tray' } }));
  expect(screen.getByRole('button', { name: 'Undo' })).toBeTruthy();
  act(() => { vi.advanceTimersByTime(3100); });
  expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
});

test('a drop outside the tray does nothing', () => {
  const onClaim = vi.fn();
  const milk = mk({ id: 'milk', name: 'Milk' });
  render(<Tray chips={[]} me="a" people={people} authorizedCents={4000} taxRate={0} onClaim={onClaim} onLeave={vi.fn()} />);
  act(() => monitor.onDragEnd!({ active: { id: 'milk', data: { current: { chip: milk, from: 'grid' } } }, over: null }));
  expect(onClaim).not.toHaveBeenCalled();
  expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
});

test('a claim over room springs back and calls onOverCap', () => {
  const onClaim = vi.fn();
  const onOverCap = vi.fn();
  const big = mk({ id: 'big', priceCents: 5000 });
  render(<Tray chips={[]} me="a" people={people} authorizedCents={4000} taxRate={0} onClaim={onClaim} onLeave={vi.fn()} onOverCap={onOverCap} />);
  act(() => monitor.onDragEnd!({ active: { id: 'big', data: { current: { chip: big, from: 'grid' } } }, over: { id: 'tray' } }));
  expect(onClaim).not.toHaveBeenCalled();
  expect(onOverCap).toHaveBeenCalledWith(big);
});

test('releasing a tray chip outside leaves and offers an Undo that claims', () => {
  const onClaim = vi.fn();
  const onLeave = vi.fn();
  render(<Tray chips={[eggs]} me="a" people={people} authorizedCents={4000} taxRate={0} onClaim={onClaim} onLeave={onLeave} />);
  act(() => monitor.onDragEnd!({ active: { id: 'tray:eggs', data: { current: { chip: eggs, from: 'tray' } } }, over: null }));
  expect(onLeave).toHaveBeenCalledWith('eggs');
  fireEvent.click(screen.getByRole('button', { name: 'Undo' }));
  expect(onClaim).toHaveBeenCalledWith('eggs');
});

test('lifting expands the tray and previews the resulting share and room', () => {
  const milk = mk({ id: 'milk', name: 'Milk', priceCents: 429 });
  const { container } = render(<Tray chips={[eggs]} me="a" people={people} authorizedCents={4000} taxRate={0} onClaim={vi.fn()} onLeave={vi.fn()} />);
  act(() => monitor.onDragStart!({ active: { id: 'milk', data: { current: { chip: milk, from: 'grid' } } } }));
  expect(container.querySelector('[data-expanded="true"]')).not.toBeNull();
  // 436 + 429 share, room 4000 - 872 - 429
  expect(screen.getByText('$40.00 held · $8.65 your share · $26.99 room')).toBeTruthy();
});

test('keyboard Enter on a grid chip calls onClaim; a wish does not', () => {
  const onClaim = vi.fn();
  const milk = mk({ id: 'milk', name: 'Milk', priceCents: 429 });
  const wish = mk({ id: 'w', name: 'Bagels', state: 'wish', wishedBy: 'b', priceCents: null });
  render(<Grid chips={[milk, wish]} me="a" people={people} onClaim={onClaim} />);
  fireEvent.keyDown(screen.getByLabelText(/^Milk/), { key: 'Enter' });
  expect(onClaim).toHaveBeenCalledWith('milk');
  fireEvent.keyDown(screen.getByLabelText(/^Wish/), { key: 'Enter' });
  expect(onClaim).toHaveBeenCalledTimes(1);
});
