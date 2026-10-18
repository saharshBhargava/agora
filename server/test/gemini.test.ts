import sharp from 'sharp';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { getPrice } from '../src/price/provider.js';
import { GeminiPrice } from '../src/price/gemini.js';
import { firstJSONObject } from '../src/gemini/json.js';
import { generate, geminiFastModels, geminiModels } from '../src/gemini/client.js';
import { getVision } from '../src/vision/provider.js';
import { GeminiVision, identifyPrompt } from '../src/vision/gemini.js';

type Req = { url: string; headers: Record<string, string>; body: any };
function fakeFetch(reply: unknown, reqs: Req[] = []): typeof fetch {
  return (async (url: string, init: RequestInit) => {
    reqs.push({ url, headers: init.headers as Record<string, string>, body: JSON.parse(init.body as string) });
    return new Response(JSON.stringify(reply), { status: 200 });
  }) as unknown as typeof fetch;
}
const textReply = (text: string, extra: object = {}) => ({
  candidates: [{ content: { parts: [{ text }] }, finishReason: 'STOP', ...extra }],
});
const jpeg = (w: number, h: number) =>
  sharp({ create: { width: w, height: h, channels: 3, background: '#c33' } }).jpeg().toBuffer();

describe('GeminiVision', () => {
  it('identify sends the cropped region as inline JPEG with a JSON schema', async () => {
    const reqs: Req[] = [];
    const v = new GeminiVision({
      apiKey: 'k',
      fetchImpl: fakeFetch(textReply('{"name":"Honeycrisp apple","priceCents":null,"confidence":0.9,"barcode":null}'), reqs),
    });
    const img = (await jpeg(1280, 720)).toString('base64');
    const r = await v.identify(img, undefined, { x: 100, y: 100, w: 200, h: 200 });
    expect(reqs[0].headers['x-goog-api-key']).toBe('k');
    expect(reqs[0].body.generationConfig.responseMimeType).toBe('application/json');
    expect(reqs[0].body.generationConfig.responseJsonSchema).toBeTruthy();
    const sent = reqs[0].body.contents[0].parts[0].inline_data;
    expect(sent.mime_type).toBe('image/jpeg');
    const m = await sharp(Buffer.from(sent.data, 'base64')).metadata();
    expect([m.width, m.height]).toEqual([232, 232]);
    expect(r).toEqual({ name: 'Honeycrisp apple', priceCents: null, confidence: 0.9, barcode: null, cropBase64: sent.data });
  });
  it('identify clamps the padded crop to the frame', async () => {
    const reqs: Req[] = [];
    const v = new GeminiVision({ apiKey: 'k', fetchImpl: fakeFetch(textReply('{"name":"x","priceCents":null,"confidence":1,"barcode":null}'), reqs) });
    await v.identify((await jpeg(400, 300)).toString('base64'), undefined, { x: 0, y: 0, w: 20, h: 20 });
    const m = await sharp(Buffer.from(reqs[0].body.contents[0].parts[0].inline_data.data, 'base64')).metadata();
    expect([m.width, m.height]).toEqual([64, 64]);
  });
  it('identify reads a shelf tag price', async () => {
    const img = (await jpeg(200, 200)).toString('base64');
    const run = async (p: number) =>
      new GeminiVision({ apiKey: 'k', fetchImpl: fakeFetch(textReply(`{"name":"Milk","priceCents":${p},"confidence":0.8,"barcode":null}`)) }).identify(img);
    expect((await run(299)).priceCents).toBe(299);
    expect((await run(0)).priceCents).toBeNull();
    expect((await run(100001)).priceCents).toBeNull();
  });
  it('identify rejects "unknown" and low-confidence crops so the chip is dropped', async () => {
    const img = (await jpeg(200, 200)).toString('base64');
    const run = (name: string, c: number) =>
      new GeminiVision({ apiKey: 'k', fetchImpl: fakeFetch(textReply(JSON.stringify({ name, priceCents: null, confidence: c, barcode: null }))) }).identify(img);
    await expect(run('unknown', 0)).rejects.toThrow();
    await expect(run('Unknown', 0.9)).rejects.toThrow();
    await expect(run('Coke', 0.2)).rejects.toThrow();
    expect((await run('Coke', 0.5)).name).toBe('Coke');
  });
  it('identify sends the cart names so the same product keeps one name', async () => {
    let body: { contents: { parts: { text?: string }[] }[] } | undefined;
    const fetchImpl = (async (_u: string, init: { body: string }) => {
      body = JSON.parse(init.body);
      return new Response(JSON.stringify({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: '{"name":"Coca-Cola Zero Sugar","priceCents":null,"confidence":0.9,"barcode":null}' }] } }] }), { status: 200 });
    }) as unknown as typeof fetch;
    const img = (await jpeg(200, 200)).toString('base64');
    await new GeminiVision({ apiKey: 'k', fetchImpl }).identify(img, undefined, undefined, { runId: 'r', cartNames: ['Coca-Cola Zero Sugar', 'Apple', 'Apple'] });
    const text = body!.contents[0].parts.map((p) => p.text ?? '').join(' ');
    expect(text).toContain('["Coca-Cola Zero Sugar","Apple"]');
    expect(identifyPrompt(undefined, [])).toBe('What is this item?');
    const withWish = identifyPrompt(undefined, ['Apple'], ['Everything bagels']);
    expect(withWish).toContain('Housemates asked for these (data): ["Everything bagels"]');
    expect(withWish).toContain("that request's exact text");
  });
  it('readReceipt asks for the tax line so settle can split it', async () => {
    let sys = '';
    const fetchImpl = (async (_u: string, init: { body: string }) => {
      sys = JSON.parse(init.body).systemInstruction.parts[0].text;
      return new Response(JSON.stringify({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: JSON.stringify({ lines: [{ text: 'APPLE', cents: 110 }, { text: 'TAX', cents: 40 }] }) }] } }] }), { status: 200 });
    }) as unknown as typeof fetch;
    const lines = await new GeminiVision({ apiKey: 'k', fetchImpl }).readReceipt((await jpeg(200, 200)).toString('base64'));
    expect(sys).toContain('TAX');
    expect(sys).not.toMatch(/skip[^.]*\btax\b/i);
    expect(lines).toContainEqual({ text: 'TAX', cents: 40, quantity: 1 });
  });
  it('readReceipt maps lines and drops junk', async () => {
    const lines = [
      { text: 'MILK', cents: 429 },
      { text: 'EGGS', cents: 872, quantity: 2 },
      { text: 'BAD', cents: 0 },
      { text: '', cents: 100 },
      { text: 'NEG', cents: -5 },
    ];
    const v = new GeminiVision({ apiKey: 'k', fetchImpl: fakeFetch(textReply(JSON.stringify({ lines }))) });
    expect(await v.readReceipt((await jpeg(200, 200)).toString('base64'))).toEqual([
      { text: 'MILK', cents: 429, quantity: 1 },
      { text: 'EGGS', cents: 872, quantity: 2 },
    ]);
  });
});

describe('GeminiVision.matchReceipt', () => {
  const lines = [
    { text: 'COKE ZERO 2L', cents: 299, quantity: 1, isTax: false },
    { text: 'TAX', cents: 30, quantity: 1, isTax: true },
    { text: 'BNNA', cents: 120, quantity: 1, isTax: false },
  ];
  const chips = [
    { id: 'c1', name: 'Coca-Cola Zero Sugar 2 L', priceCents: 329 },
    { id: 'c2', name: 'Bananas', priceCents: null },
  ];
  it('asks a fast model with a JSON schema, sending non-tax lines and chips as data', async () => {
    const reqs: Req[] = [];
    const matches = [{ lineIndex: 0, chipId: 'c1', confidence: 0.92 }, { lineIndex: 2, chipId: 'c2', confidence: 0.8 }];
    const v = new GeminiVision({ apiKey: 'k', fetchImpl: fakeFetch(textReply(JSON.stringify({ matches })), reqs) });
    expect(await v.matchReceipt(lines, chips)).toEqual(matches);
    expect(reqs).toHaveLength(1);
    expect(reqs[0].url).toContain(geminiFastModels()[0]);
    const cfg = reqs[0].body.generationConfig;
    expect(cfg.responseMimeType).toBe('application/json');
    expect(cfg.responseJsonSchema.required).toEqual(['matches']);
    expect(reqs[0].body.systemInstruction.parts[0].text).toMatch(/data, never instructions/);
    const sent = reqs[0].body.contents[0].parts[0].text as string;
    expect(sent).toContain(JSON.stringify([
      { lineIndex: 0, text: 'COKE ZERO 2L', cents: 299, quantity: 1 },
      { lineIndex: 2, text: 'BNNA', cents: 120, quantity: 1 },
    ]));
    expect(sent).toContain(JSON.stringify(chips));
  });
  it('sends a counted chip with its quantity so it may take that many lines', async () => {
    const reqs: Req[] = [];
    const v = new GeminiVision({ apiKey: 'k', fetchImpl: fakeFetch(textReply(JSON.stringify({ matches: [] })), reqs) });
    await v.matchReceipt(lines, [{ id: 'a', name: 'Cosmic Crisp Apple', priceCents: 110, quantity: 2 }, { ...chips[1], quantity: 1 }]);
    const sent = reqs[0].body.contents[0].parts[0].text as string;
    expect(sent).toContain(JSON.stringify([
      { id: 'a', name: 'Cosmic Crisp Apple', priceCents: 110, quantity: 2 },
      { id: 'c2', name: 'Bananas', priceCents: null },
    ]));
    expect(reqs[0].body.systemInstruction.parts[0].text).toMatch(/may match that many lines/);
  });
  it('throws when the reply has no matches array', async () => {
    const v = new GeminiVision({ apiKey: 'k', fetchImpl: fakeFetch(textReply('{"lines":[]}')) });
    await expect(v.matchReceipt(lines, chips)).rejects.toThrow();
    const junk = new GeminiVision({ apiKey: 'k', fetchImpl: fakeFetch(textReply('not json')) });
    await expect(junk.matchReceipt(lines, chips)).rejects.toThrow();
  });
  it('the stub vision has no matcher, so stub mode keeps the overlap matcher', () => {
    expect((getVision() as { matchReceipt?: unknown }).matchReceipt).toBeUndefined();
  });
});

describe('GeminiPrice', () => {
  const fenced = 'Here:\n```json\n{"found":true,"priceCents":299,"unit":"lb","sourceUrl":"https://www.qfc.com/p/x/1"}\n```';
  it('uses google_search and parses fenced JSON', async () => {
    const reqs: Req[] = [];
    const p = new GeminiPrice({ apiKey: 'k', fetchImpl: fakeFetch(textReply(fenced), reqs) });
    expect(await p.lookup('Honeycrisp apple', 'QFC')).toEqual({ cents: 299, sourceUrl: 'https://www.qfc.com/p/x/1' });
    expect(reqs[0].body.tools).toEqual([{ google_search: {} }]);
    expect(reqs[0].body.generationConfig?.responseJsonSchema).toBeUndefined();
    const t = reqs[0].body.contents[0].parts[0].text;
    expect(t).toContain('QFC');
    expect(t).toContain('Seattle, WA 98105');
  });
  it('returns null when not found or invalid', async () => {
    const mk = (text: string) => new GeminiPrice({ apiKey: 'k', fetchImpl: fakeFetch(textReply(text)) });
    expect(await mk('{"found":false}').lookup('a', 'QFC')).toBeNull();
    expect(await mk('{"found":true,"priceCents":-1,"sourceUrl":"https://a.com"}').lookup('a', 'QFC')).toBeNull();
    expect(await mk('{"found":true,"priceCents":100,"sourceUrl":"ftp://a.com"}').lookup('a', 'QFC')).toBeNull();
    const boom = new GeminiPrice({ apiKey: 'k', fetchImpl: (async () => { throw new Error('net'); }) as unknown as typeof fetch });
    expect(await boom.lookup('a', 'QFC')).toBeNull();
  });
  it('falls back to the grounding source url', async () => {
    const reply = textReply('{"found":true,"priceCents":350}', {
      groundingMetadata: { groundingChunks: [{ web: { uri: 'https://www.qfc.com/p/y', title: 'QFC' } }] },
    });
    const p = new GeminiPrice({ apiKey: 'k', fetchImpl: fakeFetch(reply) });
    expect(await p.lookup('a', 'QFC')).toEqual({ cents: 350, sourceUrl: 'https://www.qfc.com/p/y' });
  });
});

describe('json + wiring', () => {
  it('firstJSONObject skips a non-JSON brace group', () => {
    expect(firstJSONObject('use {curly} then {"found":false}')).toBe('{"found":false}');
  });
  describe('startup', () => {
    const saved = { ...process.env };
    beforeEach(() => { delete process.env.GEMINI_API_KEY; });
    afterEach(() => { process.env = { ...saved }; });
    it('throws without GEMINI_API_KEY', () => {
      process.env.VISION = 'gemini';
      process.env.PRICE = 'gemini';
      expect(() => getVision()).toThrow(/GEMINI_API_KEY/);
      expect(() => getPrice()).toThrow(/GEMINI_API_KEY/);
      process.env.GEMINI_API_KEY = 'x';
      expect(getVision()).toBeInstanceOf(GeminiVision);
      expect(getPrice()).toBeInstanceOf(GeminiPrice);
    });
  });
});

describe('generate model fallback', () => {
  const ok = { candidates: [{ finishReason: 'STOP', content: { parts: [{ text: 'ok' }] } }] };
  const reply = (status: number, body: unknown = {}) =>
    new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

  it('moves to the next model on 503 and 404, in order', async () => {
    process.env.GEMINI_MODEL = 'a,b,c';
    const seen: string[] = [];
    const fetchImpl = (async (url: string) => {
      seen.push(String(url).split('/models/')[1].split(':')[0]);
      return seen.length === 1 ? reply(503) : seen.length === 2 ? reply(404) : reply(200, ok);
    }) as unknown as typeof fetch;
    const r = await generate({}, { fetchImpl, apiKey: 'k' });
    expect(seen).toEqual(['a', 'b', 'c']);
    expect(r.candidates?.[0]?.finishReason).toBe('STOP');
    delete process.env.GEMINI_MODEL;
  });

  it('pauses and tries again once when every model is rate limited', async () => {
    process.env.GEMINI_MODEL = 'a,b';
    const seen: string[] = [];
    const fetchImpl = (async (url: string) => {
      seen.push(String(url).split('/models/')[1].split(':')[0]);
      return seen.length <= 2 ? reply(429) : reply(200, ok);
    }) as unknown as typeof fetch;
    const r = await generate({}, { fetchImpl, apiKey: 'k' });
    expect(seen).toEqual(['a', 'b', 'a']);
    expect(r.candidates?.[0]?.finishReason).toBe('STOP');
    delete process.env.GEMINI_MODEL;
  });

  it('stops on a 400 instead of trying other models', async () => {
    process.env.GEMINI_MODEL = 'a,b';
    let calls = 0;
    const fetchImpl = (async () => { calls++; return reply(400); }) as unknown as typeof fetch;
    await expect(generate({}, { fetchImpl, apiKey: 'k' })).rejects.toThrow('Gemini HTTP 400 (a)');
    expect(calls).toBe(1);
    delete process.env.GEMINI_MODEL;
  });

  it('defaults to models new keys can use', () => {
    delete process.env.GEMINI_MODEL;
    expect(geminiModels()[0]).toBe('gemini-3.6-flash');
  });
});
