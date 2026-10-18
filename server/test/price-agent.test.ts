import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { buildServer } from '../src/index.js';
import { SimPayments } from '../src/payments/sim.js';
import { AgentPrice } from '../src/price/agent.js';
import { chain } from '../src/price/chain.js';
import { getPriceSetup, type PriceProvider } from '../src/price/provider.js';
import { StubPrice } from '../src/price/stub.js';
import { StubVision } from '../src/vision/stub.js';
import type { Identified } from '../src/vision/provider.js';

let app: FastifyInstance | undefined;
afterEach(async () => {
  vi.useRealTimers();
  await app?.close();
  app = undefined;
  delete process.env.PRICE;
});

const geminiReply = (obj: object) => ({
  candidates: [{ finishReason: 'STOP', content: { parts: [{ text: JSON.stringify(obj) }] } }],
});
function fakeFetch(reply: unknown, status = 200, reqs: any[] = []): typeof fetch {
  return (async (_u: string, init: RequestInit) => {
    reqs.push(JSON.parse(init.body as string));
    return new Response(JSON.stringify(reply), { status });
  }) as unknown as typeof fetch;
}

async function start(over: Partial<Parameters<typeof buildServer>[0]> = {}) {
  process.env.GEMINI_API_KEY = 'k';
  app = await buildServer({
    payments: new SimPayments(),
    vision: new StubVision(),
    price: new StubPrice(),
    dataDir: mkdtempSync(join(tmpdir(), 'dibs-')),
    ...over,
  });
  return app;
}

describe('chain', () => {
  const fixed = (r: { cents: number; sourceUrl: string } | null, calls: string[], tag: string): PriceProvider => ({
    async lookup() {
      calls.push(tag);
      return r;
    },
  });
  it('returns the first non-null in order and falls through', async () => {
    const calls: string[] = [];
    const a = { cents: 1, sourceUrl: 'https://a' };
    const b = { cents: 2, sourceUrl: 'https://b' };
    expect(await chain([fixed(null, calls, 'x'), fixed(a, calls, 'a'), fixed(b, calls, 'b')]).lookup('n', 'QFC')).toEqual(a);
    expect(calls).toEqual(['x', 'a']);
    expect(await chain([fixed(null, [], 'x')]).lookup('n', 'QFC')).toBeNull();
  });
});

describe('PRICE list', () => {
  it('builds a chain with one shared AgentPrice', () => {
    process.env.PRICE = 'agent';
    const one = getPriceSetup();
    expect(one.agent).toBeInstanceOf(AgentPrice);
    expect(one.provider).toBe(one.agent);
    process.env.PRICE = 'agent,stub';
    expect(getPriceSetup().agent).toBeInstanceOf(AgentPrice);
    process.env.PRICE = 'stub';
    expect(getPriceSetup().agent).toBeUndefined();
  });
});

describe('AgentPrice', () => {
  it('resolves on POST and lists only open requests', async () => {
    const agent = new AgentPrice();
    const a = await start({ agent });
    const p = agent.lookup('Honeycrisp apple & pears', 'QFC');
    const list = (await a.inject({ url: '/api/price-requests?open=1' })).json();
    expect(list).toHaveLength(1);
    expect(list[0]).toEqual({
      id: expect.any(String),
      name: 'Honeycrisp apple & pears',
      store: 'QFC',
      searchUrl: 'https://www.qfc.com/search?query=Honeycrisp%20apple%20%26%20pears',
    });
    const r = await a.inject({ method: 'POST', url: `/api/price-requests/${list[0].id}`, payload: { cents: 299, url: 'https://www.qfc.com/p/x' } });
    expect(r.statusCode).toBe(200);
    expect(await p).toEqual({ cents: 299, sourceUrl: 'https://www.qfc.com/p/x' });
    expect((await a.inject({ url: '/api/price-requests?open=1' })).json()).toEqual([]);
  });

  it('times out to null and the id is gone', async () => {
    const agent = new AgentPrice({ timeoutMs: 1000 });
    const a = await start({ agent });
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    const p = agent.lookup('milk', 'QFC');
    const id = agent.open()[0].id;
    await vi.advanceTimersByTimeAsync(1001);
    expect(await p).toBeNull();
    const r = await a.inject({ method: 'POST', url: `/api/price-requests/${id}`, payload: { cents: 100, url: 'https://x.com' } });
    expect(r.statusCode).toBe(404);
  });

  it('validates cents and url', async () => {
    const agent = new AgentPrice();
    const a = await start({ agent });
    void agent.lookup('milk', 'QFC');
    const id = agent.open()[0].id;
    for (const body of [
      { cents: 0, url: 'https://x.com' },
      { cents: 100001, url: 'https://x.com' },
      { cents: 1.5, url: 'https://x.com' },
      { cents: 100, url: 'http://x.com' },
      { cents: 100 },
      { cents: '100', url: 'https://x.com' },
    ]) {
      const r = await a.inject({ method: 'POST', url: `/api/price-requests/${id}`, payload: body });
      expect(r.statusCode).toBe(400);
    }
    expect(agent.open()).toHaveLength(1);
    const unknown = await a.inject({ method: 'POST', url: '/api/price-requests/nope', payload: { cents: 100, url: 'https://x.com' } });
    expect(unknown.statusCode).toBe(404);
  });

  it('extract resolves the pending lookup from a canned Gemini reply', async () => {
    const agent = new AgentPrice();
    const reqs: any[] = [];
    const a = await start({
      agent,
      fetchImpl: fakeFetch(geminiReply({ found: true, productName: 'Honeycrisp Apples', priceCents: 349, unit: 'lb' }), 200, reqs),
    });
    const p = agent.lookup('apple', 'QFC');
    const id = agent.open()[0].id;
    const r = await a.inject({ method: 'POST', url: `/api/price-requests/${id}/extract`, payload: { pageText: 'x'.repeat(30000) } });
    expect(r.json()).toEqual({ found: true, priceCents: 349, productName: 'Honeycrisp Apples', unit: 'lb' });
    expect(await p).toEqual({ cents: 349, sourceUrl: 'https://www.qfc.com/search?query=apple' });
    const sent = reqs[0];
    expect(sent.generationConfig.responseMimeType).toBe('application/json');
    expect(sent.generationConfig.responseJsonSchema.properties.priceCents.type).toBe('integer');
    const text: string = sent.contents[0].parts[0].text;
    expect(text.startsWith('Item: "apple". Store: QFC. Page text:\n')).toBe(true);
    expect(text.length).toBe('Item: "apple". Store: QFC. Page text:\n'.length + 20000);
  });

  it('extract found:false leaves the request open', async () => {
    const agent = new AgentPrice();
    const a = await start({ agent, fetchImpl: fakeFetch(geminiReply({ found: false, productName: '', priceCents: 0, unit: '' })) });
    void agent.lookup('apple', 'QFC');
    const id = agent.open()[0].id;
    const r = await a.inject({ method: 'POST', url: `/api/price-requests/${id}/extract`, payload: { pageText: 'nothing' } });
    expect(r.json()).toEqual({ found: false });
    expect(agent.open()).toHaveLength(1);
  });

  it('extract maps Gemini errors to 502 and bad bodies to 400', async () => {
    const agent = new AgentPrice();
    const a = await start({ agent, fetchImpl: fakeFetch({}, 400) });
    void agent.lookup('apple', 'QFC');
    const id = agent.open()[0].id;
    const r = await a.inject({ method: 'POST', url: `/api/price-requests/${id}/extract`, payload: { pageText: 'x' } });
    expect(r.statusCode).toBe(502);
    expect(r.json()).toEqual({ error: 'extract failed' });
    const bad = await a.inject({ method: 'POST', url: `/api/price-requests/${id}/extract`, payload: { pageText: 5 } });
    expect(bad.statusCode).toBe(400);
  });

  it('routes 404 when no agent provider is active', async () => {
    const a = await start();
    expect((await a.inject({ url: '/api/price-requests?open=1' })).statusCode).toBe(404);
    expect((await a.inject({ method: 'POST', url: '/api/price-requests/x', payload: { cents: 1, url: 'https://x.com' } })).statusCode).toBe(404);
    expect((await a.inject({ method: 'POST', url: '/api/price-requests/x/extract', payload: { pageText: 'x' } })).statusCode).toBe(404);
  });
});

describe('hint cap', () => {
  it('forwards at most 200 chars and ignores non-strings', async () => {
    const hints: (string | undefined)[] = [];
    const vision = new StubVision();
    vision.identify = async (_img: string, hint?: string): Promise<Identified> => {
      hints.push(hint);
      return { name: 'thing', priceCents: 100, confidence: 1, barcode: null, cropBase64: '' };
    };
    const a = await start({ vision });
    const { runId } = (await a.inject({ method: 'POST', url: '/api/runs' })).json();
    await a.inject({ method: 'POST', url: `/api/runs/${runId}/chips`, payload: { imageBase64: '', hint: 'h'.repeat(500) } });
    await a.inject({ method: 'POST', url: `/api/runs/${runId}/chips`, payload: { imageBase64: '', hint: { evil: 1 } } });
    expect(hints[0]).toHaveLength(200);
    expect(hints[1]).toBeUndefined();
  });
});
