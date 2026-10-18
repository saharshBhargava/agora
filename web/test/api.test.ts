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

test('createRun sends a JSON body so the server accepts the POST', async () => {
  const fetchMock = vi.fn(async (..._a: unknown[]) => ({ ok: true, json: async () => ({ runId: 'r', shopperId: 's' }) }));
  vi.stubGlobal('fetch', fetchMock);
  await api.createRun();
  expect((fetchMock.mock.calls[0][1] as RequestInit).body).toBe('{}');
});

// ---- per-person keys ----
import { clearKeys, keyFor, saveKey } from '@/lib/keys';

function stubFetch(body: unknown = {}) {
  const fetchMock = vi.fn(async (..._a: unknown[]) => ({ ok: true, json: async () => body }));
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}
const headerOf = (fetchMock: ReturnType<typeof stubFetch>, i = 0) =>
  ((fetchMock.mock.calls[i][1] as RequestInit).headers as Record<string, string>)['x-dibs-key'];

test('createRun and join keep the key the server hands out, per run and person', async () => {
  clearKeys();
  stubFetch({ runId: 'r9', shopperId: 'shop-uuid', key: 'shopper-key' });
  await api.createRun();
  expect(keyFor('r9', 'shop-uuid')).toBe('shopper-key');
  stubFetch({ personId: 'p7', key: 'claimer-key', auth: { status: 'AUTHORIZED', authId: null, approvalCode: '888888', authorizedCents: 4000 } });
  await api.join('r9', 'Priya', 4000);
  expect(keyFor('r9', 'p7')).toBe('claimer-key');
  expect(keyFor('r9', 'shop-uuid')).toBe('shopper-key');
  expect(keyFor('other', 'p7')).toBeNull();
});

test('every action sends the acting person\'s key in x-dibs-key', async () => {
  clearKeys();
  saveKey('r1', 'shop', 'K-shop');
  saveKey('r1', 'p1', 'K-p1');
  const calls: [string, () => Promise<unknown>][] = [
    ['K-shop', () => api.addChip('r1', 'shop', { imageBase64: '' })],
    ['K-shop', () => api.fixChip('r1', 'c1', 'shop', { name: 'Eggs' })],
    ['K-shop', () => api.setQuantity('r1', 'c1', 'shop', 2)],
    ['K-shop', () => api.putBack('r1', 'c1', 'shop')],
    ['K-shop', () => api.checkout('r1', 'shop')],
    ['K-shop', () => api.back('r1', 'shop')],
    ['K-shop', () => api.receipt('r1', 'shop', '')],
    ['K-shop', () => api.fixReceiptLine('r1', 'shop', 0, 'mine')],
    ['K-shop', () => api.confirm('r1', 'shop')],
    ['K-p1', () => api.raise('r1', 'p1', 6000)],
    ['K-p1', () => api.wish('r1', 'Bagels', 'p1')],
  ];
  for (const [key, call] of calls) {
    const fetchMock = stubFetch();
    await call();
    expect(headerOf(fetchMock)).toBe(key);
  }
});

test('a person this browser has no key for sends none (the server refuses it)', async () => {
  clearKeys();
  const fetchMock = stubFetch();
  await api.checkout('r1', 'someone-else');
  expect(headerOf(fetchMock)).toBeUndefined();
});
