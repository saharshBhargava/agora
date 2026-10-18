import { act, fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, expect, test, vi } from 'vitest';
import type { Chip, Run } from '@/lib/types';

const chip: Chip = {
  id: 'eggs', name: 'Eggs', priceCents: 872, priceSource: 'sticker', photoUrl: null, region: null, quantity: 1,
  claimers: [], state: 'open', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
  overCap: [], removedAt: null, addedAt: 0,
};
const run: Run = {
  id: 'r1', state: 'open', store: 'Costco', shopperId: 'shop', taxRate: 0, lastCallEndsAt: null,
  receipt: null, settle: {}, payout: null,
  people: [{ id: 'shop', name: 'Sam', initial: 'S', isShopper: true, authorizedCents: null, authId: null, approvalCode: null, payoutPan: null }],
  chips: [chip],
};
const send = vi.fn(() => true);
let sock: Record<string, unknown>;
vi.mock('@/lib/socket', () => ({ useRun: () => sock }));
const fixChip = vi.fn(async () => ({}));
vi.mock('@/lib/api', () => ({ api: { fixChip: (...a: unknown[]) => (fixChip as (...x: unknown[]) => unknown)(...a) } }));
vi.mock('next/navigation', () => ({ useSearchParams: () => new URLSearchParams('run=r1&person=shop&mock=1'), useRouter: () => ({ push: vi.fn(), replace: vi.fn() }) }));
// jsdom cannot drag: stand in for Board and drive its remove/tap callbacks directly.
vi.mock('@/components/Board', () => ({
  Board: (p: { onRemove: (id: string) => void; onTap: (id: string) => void }) => (
    <div>
      <button onClick={() => p.onRemove('eggs')}>drop on remove</button>
      <button onClick={() => p.onTap('eggs')}>tap chip</button>
    </div>
  ),
}));

import ShopperScreen from '@/app/shopper/ShopperScreen';

beforeEach(() => {
  send.mockClear();
  fixChip.mockClear();
  send.mockImplementation(() => true);
  sock = { run, send, connected: true, lastFrame: null, lastCallEndsAt: null, identifyingRegion: null, error: null, errorEvent: null };
});

test('drop on remove sends remove, shows an Undo toast that sends undoRemove', () => {
  render(<ShopperScreen />);
  fireEvent.click(screen.getByText('drop on remove'));
  expect(send).toHaveBeenCalledWith({ t: 'remove', chipId: 'eggs' });
  fireEvent.click(screen.getByRole('button', { name: 'Undo' }));
  expect(send).toHaveBeenCalledWith({ t: 'undoRemove', chipId: 'eggs' });
});

test('no Undo toast when the remove was not sent', () => {
  send.mockImplementation(() => false);
  render(<ShopperScreen />);
  fireEvent.click(screen.getByText('drop on remove'));
  expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
});

test('tapping a chip opens FixChipSheet; save sends integer cents; Escape closes', async () => {
  render(<ShopperScreen />);
  fireEvent.click(screen.getByText('tap chip'));
  fireEvent.change(screen.getByLabelText('Price'), { target: { value: '9.5' } });
  fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Big Eggs' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  await act(async () => {});
  expect(fixChip).toHaveBeenCalledWith('r1', 'eggs', 'shop', { name: 'Big Eggs', priceCents: 950 });
  fireEvent.click(screen.getByText('tap chip'));
  expect(screen.getByRole('dialog')).toBeInTheDocument();
  fireEvent.keyDown(window, { key: 'Escape' });
  expect(screen.queryByRole('dialog')).toBeNull();
});
