import { afterEach, expect, test, vi } from 'vitest';
import { api } from '@/lib/api';

afterEach(() => vi.unstubAllGlobals());

test('every request carries a 10 s timeout signal', async () => {
  const fetchMock = vi.fn(async (..._a: unknown[]) => ({ ok: true, json: async () => ({ runId: 'r', shopperId: 's' }) }));
  vi.stubGlobal('fetch', fetchMock);
  await api.createRun();
  const init = fetchMock.mock.calls[0][1] as RequestInit;
  expect(init.signal).toBeInstanceOf(AbortSignal);
});

test('a timeout becomes friendly copy', async () => {
  vi.stubGlobal('fetch', vi.fn(async () => { throw new DOMException('signal timed out', 'TimeoutError'); }));
  await expect(api.createRun()).rejects.toThrow('The server is taking too long. Try again.');
});

test('a network failure becomes friendly copy', async () => {
  vi.stubGlobal('fetch', vi.fn(async () => { throw new TypeError('Failed to fetch'); }));
  await expect(api.createRun()).rejects.toThrow("Can't reach the server. Check your connection and try again.");
});
