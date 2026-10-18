import { act, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import type { Chip, Run } from '@/lib/types';

const mk = (o: Partial<Chip>): Chip => ({
  id: 'c', name: 'Item', priceCents: 100, priceSource: 'sticker', photoUrl: null, region: null, quantity: 1,
  claimers: [], state: 'open', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
  overCap: [], removedAt: null, addedAt: 0, ...o,
});
const baseRun = (o: Partial<Run> = {}): Run => ({
  id: 'r1', state: 'open', store: 'Costco', shopperId: 'shop', taxRate: 0, lastCallEndsAt: null,
  receipt: null, settle: {}, payout: null,
  people: [{ id: 'shop', name: 'Sam', initial: 'S', isShopper: true, authorizedCents: null, authId: null, payoutPan: null }],
  chips: [],
  ...o,
});

// --- mocks ---
const sendMock = vi.fn(() => true);
let sock: Record<string, unknown>;
vi.mock('@/lib/socket', () => ({ useRun: () => sock }));
const addChip = vi.fn(async () => ({}));
const putBack = vi.fn(async () => ({}));
const back = vi.fn(async () => ({}));
vi.mock('@/lib/api', () => ({
  api: {
    addChip: (...a: unknown[]) => (addChip as (...x: unknown[]) => unknown)(...a),
    putBack: (...a: unknown[]) => (putBack as (...x: unknown[]) => unknown)(...a),
    back: (...a: unknown[]) => (back as (...x: unknown[]) => unknown)(...a),
    checkout: vi.fn(async () => ({})),
    fixChip: vi.fn(async () => ({})),
  },
}));
let params = new URLSearchParams('run=r1&person=shop&mock=1');
vi.mock('next/navigation', () => ({ useSearchParams: () => params }));

import ShopperScreen from '@/app/shopper/ShopperScreen';
import { Camera } from '@/components/Camera';
import { UnclaimedList } from '@/components/UnclaimedList';
import { frameBoxToDisplay, tapToFrame } from '@/lib/frame';

const setSock = (run: Run | null, extra: Record<string, unknown> = {}) => {
  sock = {
    run, send: sendMock, connected: true, lastFrame: null, lastCallEndsAt: null, identifyingRegion: null, error: null,
    ...extra,
  };
};

beforeEach(() => {
  sendMock.mockClear();
  addChip.mockClear();
  putBack.mockClear();
  back.mockClear();
  params = new URLSearchParams('run=r1&person=shop&mock=1');
  setSock(baseRun());
  vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer })));
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

test('Camera sends a frame within 600 ms of mounting', async () => {
  vi.useFakeTimers();
  const track = { stop: vi.fn() };
  const getUserMedia = vi.fn(async () => ({ getTracks: () => [track] }));
  Object.defineProperty(navigator, 'mediaDevices', { value: { getUserMedia }, configurable: true });
  Object.defineProperty(HTMLVideoElement.prototype, 'videoWidth', { value: 1280, configurable: true });
  Object.defineProperty(HTMLVideoElement.prototype, 'videoHeight', { value: 720, configurable: true });
  const drawImage = vi.fn();
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue({ drawImage } as unknown as CanvasRenderingContext2D);
  const toDataURL = vi.spyOn(HTMLCanvasElement.prototype, 'toDataURL').mockReturnValue('data:image/jpeg;base64,QUJD');
  const send = vi.fn(() => true);
  const { unmount } = render(<Camera send={send} enabled region={null} mockHref="?mock=1" />);
  await act(async () => {
    await vi.advanceTimersByTimeAsync(0); // camera granted
  });
  await act(async () => {
    await vi.advanceTimersByTimeAsync(600);
  });
  expect(getUserMedia).toHaveBeenCalledWith({ video: { facingMode: 'environment' }, audio: false });
  expect(send).toHaveBeenCalledWith(expect.objectContaining({ t: 'frame', jpegBase64: 'QUJD' }));
  expect(toDataURL).toHaveBeenCalledWith('image/jpeg', 0.6);
  expect(drawImage.mock.calls[0].slice(1)).toEqual([0, 0, 640, 360]);
  unmount();
  expect(track.stop).toHaveBeenCalled();
});

test('Camera shows a friendly message and demo link when permission is denied', async () => {
  Object.defineProperty(navigator, 'mediaDevices', {
    value: { getUserMedia: vi.fn(async () => { throw new Error('denied'); }) }, configurable: true,
  });
  render(<Camera send={vi.fn(() => true)} enabled region={null} mockHref="?mock=1" />);
  expect(await screen.findByRole('link', { name: 'Use demo props' })).toHaveAttribute('href', '?mock=1');
});

test('tapToFrame maps a tap through object-fit cover to frame pixels', () => {
  // 1280x720 video in a 200x200 box: scale 200/720, horizontally cropped.
  const box = { left: 10, top: 20, width: 200, height: 200 };
  const c = tapToFrame(box, 1280, 720, 110, 120); // center of the box
  expect(c).toEqual({ x: 320, y: 180 });
  expect(tapToFrame(box, 1280, 720, 10, 20)).toEqual({ x: 140, y: 0 });
  const r = frameBoxToDisplay({ x: 288, y: 162, w: 64, h: 36 }, { width: 200, height: 200 }, 1280, 720);
  expect(Math.round(r.left + r.width / 2)).toBe(100);
  expect(Math.round(r.top + r.height / 2)).toBe(100);
});

test('mock mode: Eggs posts the prop and the chip appears in the grid', async () => {
  const { rerender } = render(<ShopperScreen />);
  fireEvent.click(screen.getByRole('button', { name: 'Eggs' }));
  await act(async () => {});
  expect(addChip).toHaveBeenCalledWith('r1', expect.objectContaining({ hint: 'eggs' }));
  setSock(baseRun({ chips: [mk({ id: 'e', name: 'Eggs', priceCents: 872 })] }));
  rerender(<ShopperScreen />);
  expect(screen.getByLabelText(/^Eggs/)).toBeInTheDocument();
});

test('non-shopper person is pointed to the claim page', () => {
  params = new URLSearchParams('run=r1&person=other&mock=1');
  render(<ShopperScreen />);
  expect(screen.getByText(/This page is for the shopper/)).toBeInTheDocument();
  expect(screen.getByRole('link', { name: /claim/i })).toHaveAttribute('href', '/claim?run=r1&person=other');
});

test('Checkout calls the checkout route; last call shows a banner', async () => {
  const { api } = await import('@/lib/api');
  const { rerender } = render(<ShopperScreen />);
  fireEvent.click(screen.getByRole('button', { name: 'Checkout' }));
  await act(async () => {});
  expect(api.checkout).toHaveBeenCalledWith('r1', 'shop');
  setSock(baseRun({ state: 'lastCall', lastCallEndsAt: Date.now() + 5000 }), { lastCallEndsAt: Date.now() + 5000 });
  rerender(<ShopperScreen />);
  expect(screen.getByText(/Last call/)).toBeInTheDocument();
});

test('identify failure shows the retry hint', () => {
  setSock(baseRun(), { error: 'identify failed' });
  render(<ShopperScreen />);
  expect(screen.getByText("Couldn't identify. Tap it again or name it")).toBeInTheDocument();
});

test('a duplicate chip offers Keep both / Remove one', () => {
  setSock(baseRun({ chips: [mk({ id: 'm1', name: 'Milk' }), mk({ id: 'm2', name: 'Milk', duplicateOf: 'm1' })] }));
  render(<ShopperScreen />);
  fireEvent.click(screen.getByRole('button', { name: 'Remove one' }));
  expect(sendMock).toHaveBeenCalledWith({ t: 'remove', chipId: 'm2' });
});

test('UnclaimedList shows Mine and Put back for the milk when locked', async () => {
  const run = baseRun({ state: 'locked', chips: [mk({ id: 'milk', name: 'Milk', priceCents: 429, state: 'locked' })] });
  const onPutBack = vi.fn();
  const onBack = vi.fn();
  render(<UnclaimedList run={run} personId="shop" onPutBack={onPutBack} onBack={onBack} />);
  expect(screen.getByText('Milk')).toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Mine' })).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Put back' }));
  expect(onPutBack).toHaveBeenCalledWith('milk');
  fireEvent.click(screen.getByRole('button', { name: 'Back to cart' }));
  expect(onBack).toHaveBeenCalled();
  expect(screen.getByRole('link', { name: 'Go to settle' })).toHaveAttribute('href', '/settle?run=r1&person=shop');
});
