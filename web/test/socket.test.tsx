import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { useRun } from '@/lib/socket';

class FakeWS {
  static instances: FakeWS[] = [];
  static OPEN = 1;
  readyState = 0;
  sent: string[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((e: { data: string }) => void) | null = null;
  onerror: (() => void) | null = null;
  constructor(public url: string) {
    FakeWS.instances.push(this);
  }
  send(d: string) {
    this.sent.push(d);
  }
  onclose: ((e?: { code?: number }) => void) | null = null;
  close(code?: number) {
    this.readyState = 3;
    this.onclose?.({ code });
  }
  open() {
    this.readyState = 1;
    this.onopen?.();
  }
  push(m: unknown) {
    this.onmessage?.({ data: JSON.stringify(m) });
  }
}

beforeEach(() => {
  FakeWS.instances = [];
  vi.useFakeTimers();
  vi.stubGlobal('WebSocket', FakeWS);
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

const last = () => FakeWS.instances[FakeWS.instances.length - 1];

test('connects to /ws with run and person, pushes run state', () => {
  const { result } = renderHook(() => useRun('r1', 'p1'));
  expect(last().url).toMatch(/\/ws\?run=r1&person=p1$/);
  act(() => last().open());
  act(() => last().push({ t: 'run', run: { id: 'r1' } }));
  expect(result.current.connected).toBe(true);
  expect(result.current.run).toMatchObject({ id: 'r1' });
});

test('reconnects after close', () => {
  const { result } = renderHook(() => useRun('r1', 'p1'));
  act(() => last().open());
  act(() => last().close());
  expect(result.current.connected).toBe(false);
  expect(FakeWS.instances).toHaveLength(1);
  act(() => void vi.advanceTimersByTime(6000));
  expect(FakeWS.instances).toHaveLength(2);
  act(() => last().open());
  expect(result.current.connected).toBe(true);
});

test('keeps only the latest frame', () => {
  const { result } = renderHook(() => useRun('r1', 'p1'));
  act(() => last().open());
  act(() => last().push({ t: 'frame', jpegBase64: 'AAA', at: 1 }));
  act(() => last().push({ t: 'frame', jpegBase64: 'BBB', at: 2 }));
  expect(result.current.lastFrame).toBe('data:image/jpeg;base64,BBB');
});

test('handles lastCall and identifying', () => {
  const { result } = renderHook(() => useRun('r1', 'p1'));
  act(() => last().open());
  act(() => last().push({ t: 'lastCall', endsAt: 12345 }));
  expect(result.current.lastCallEndsAt).toBe(12345);
  const region = { x: 1, y: 2, w: 3, h: 4 };
  act(() => last().push({ t: 'identifying', region }));
  expect(result.current.identifyingRegion).toEqual(region);
  act(() => last().push({ t: 'error', reason: 'nope' }));
  expect(result.current.error).toBe('nope');
  expect(result.current.errorEvent).toEqual({ reason: 'nope', seq: 1 });
  act(() => last().push({ t: 'error', reason: 'nope' }));
  expect(result.current.errorEvent).toEqual({ reason: 'nope', seq: 2 });
});

test('does not reconnect after unmount', () => {
  const { unmount } = renderHook(() => useRun('r1', 'p1'));
  act(() => last().open());
  unmount();
  act(() => void vi.advanceTimersByTime(10000));
  expect(FakeWS.instances).toHaveLength(1);
});

test('send returns false and sets Reconnecting while closed, true when open', () => {
  const { result } = renderHook(() => useRun('r1', 'p1'));
  let ok = true;
  act(() => {
    ok = result.current.send({ t: 'x' });
  });
  expect(ok).toBe(false);
  expect(result.current.error).toBe('Reconnecting…');
  act(() => last().open());
  expect(result.current.error).toBeNull();
  act(() => {
    ok = result.current.send({ t: 'claim' });
  });
  expect(ok).toBe(true);
  expect(last().sent).toEqual([JSON.stringify({ t: 'claim' })]);
});

test('no GET re-sync on open: a pushed run is never overwritten', () => {
  const fetchSpy = vi.fn();
  vi.stubGlobal('fetch', fetchSpy);
  const { result } = renderHook(() => useRun('r1', 'p1'));
  act(() => last().open());
  act(() => last().push({ t: 'run', run: { id: 'r1', state: 'locked' } }));
  expect(fetchSpy).not.toHaveBeenCalled();
  expect(result.current.run).toMatchObject({ state: 'locked' });
});

test('resets state when ids change', () => {
  const { result, rerender } = renderHook(({ r }) => useRun(r, 'p1'), { initialProps: { r: 'r1' } });
  act(() => last().open());
  act(() => last().push({ t: 'run', run: { id: 'r1' } }));
  rerender({ r: 'r2' });
  expect(result.current.run).toBeNull();
  expect(last().url).toMatch(/run=r2/);
});

test('a run with no identifying chip clears the identifying region', () => {
  const { result } = renderHook(() => useRun('r1', 'p1'));
  act(() => last().open());
  const region = { x: 1, y: 2, w: 3, h: 4 };
  act(() => last().push({ t: 'identifying', region }));
  act(() => last().push({ t: 'run', run: { id: 'r1', lastCallEndsAt: null, chips: [{ id: 'c', state: 'identifying', dropped: false }] } }));
  expect(result.current.identifyingRegion).toEqual(region);
  act(() => last().push({ t: 'run', run: { id: 'r1', lastCallEndsAt: null, chips: [{ id: 'c', state: 'open', dropped: false }] } }));
  expect(result.current.identifyingRegion).toBeNull();
});

test('close code 1008 stops reconnecting and marks the run ended', () => {
  const { result } = renderHook(() => useRun('r1', 'p1'));
  expect(result.current.ended).toBe(false);
  act(() => last().close(1008));
  act(() => void vi.advanceTimersByTime(10000));
  expect(FakeWS.instances).toHaveLength(1);
  expect(result.current.ended).toBe(true);
});
