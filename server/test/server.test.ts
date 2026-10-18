import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { AddressInfo } from 'node:net';
import type { FastifyInstance } from 'fastify';
import WebSocket from 'ws';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildServer, qrJoinUrl } from '../src/index.js';
import { checkout } from '../src/run.js';
import { seedRun } from '../src/seed.js';
import { SimPayments } from '../src/payments/sim.js';
import { StubPrice } from '../src/price/stub.js';
import { StubVision } from '../src/vision/stub.js';
import type { Run } from '../src/types.js';
import { sharesFor } from '../src/run.js';
import type { Identified } from '../src/vision/provider.js';
import type { PriceProvider } from '../src/price/provider.js';

const card = { number: '4111111111111111', expMonth: 12, expYear: 2030 };
let app: FastifyInstance;
let payments: SimPayments;
let port: number;
const sockets: WebSocket[] = [];

async function start(over: Partial<Parameters<typeof buildServer>[0]> = {}) {
  payments = new SimPayments();
  app = await buildServer({
    payments,
    vision: new StubVision(),
    price: new StubPrice(),
    lastCallMs: 50,
    dataDir: mkdtempSync(join(tmpdir(), 'dibs-')),
    ...over,
  });
  await app.listen({ port: 0, host: '127.0.0.1' });
  port = (app.server.address() as AddressInfo).port;
}

beforeEach(() => start());

afterEach(async () => {
  for (const s of sockets.splice(0)) s.terminate();
  await app.close();
  delete process.env.RAISE_CAP;
});

async function post(path: string, body: unknown = {}) {
  const r = await app.inject({ method: 'POST', url: path, payload: body as object });
  return { status: r.statusCode, body: r.json() };
}
const getRun = async (id: string): Promise<Run> => (await app.inject({ url: `/api/runs/${id}` })).json();

type Msg = { t: string; [k: string]: unknown };
function connect(runId: string, personId: string) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?run=${runId}&person=${personId}`);
  sockets.push(ws);
  const msgs: Msg[] = [];
  ws.on('message', (d) => msgs.push(JSON.parse(String(d))));
  const opened = new Promise<void>((res) => ws.on('open', () => res()));
  const waitFor = async (pred: (m: Msg) => boolean) => {
    for (let i = 0; i < 200; i++) {
      const m = msgs.find(pred);
      if (m) return m;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error('timeout waiting for message');
  };
  return { ws, msgs, opened, waitFor, send: (m: object) => ws.send(JSON.stringify(m)) };
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function setup() {
  const { body: created } = await post('/api/runs');
  const runId = created.runId as string;
  const shopperId = created.shopperId as string;
  const a = (await post(`/api/runs/${runId}/join`, { name: 'Ann', card, capCents: 3000 })).body;
  const b = (await post(`/api/runs/${runId}/join`, { name: 'Bo', card, capCents: 4000 })).body;
  return { runId, shopperId, A: a.personId as string, B: b.personId as string };
}

describe('dibs server', () => {
  it('runs the whole flow', async () => {
    const { runId, shopperId, A, B } = await setup();
    expect((await post(`/api/runs/${runId}/join`, { name: 'X', card: { ...card, expYear: 1998 }, capCents: 1000 })).status).toBe(409);

    const eggs = (await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint: 'eggs' })).body;
    const towels = (await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint: 'towels' })).body;
    const milk = (await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint: 'milk' })).body;
    expect(eggs.priceCents).toBe(872);
    expect(eggs.state).toBe('open');

    const wa = connect(runId, A);
    const wb = connect(runId, B);
    await Promise.all([wa.opened, wb.opened]);
    await wa.waitFor((m) => m.t === 'run');
    const act = async (c: ReturnType<typeof connect>, m: object) => {
      const n = c.msgs.length;
      c.send(m);
      for (let i = 0; i < 200 && c.msgs.length === n; i++) await sleep(10);
      expect(c.msgs.length).toBeGreaterThan(n);
    };
    await act(wa, { t: 'claim', chipId: eggs.id });
    await act(wb, { t: 'claim', chipId: eggs.id });
    // Shares are derived with the pure sharesFor over the GET payload: the eggs split evenly.
    const early = sharesFor(await getRun(runId));
    expect(early.get(A)).toBe(436);
    expect(early.get(B)).toBe(436);
    await act(wb, { t: 'claim', chipId: towels.id });
    await act(wa, { t: 'claim', chipId: milk.id });
    await act(wa, { t: 'leave', chipId: milk.id });
    await act(wb, { t: 'claim', chipId: milk.id });

    const run1 = await getRun(runId);
    const [e, t, m] = run1.chips;
    expect(e.claimers).toEqual([A, B]);
    expect(t.claimers).toEqual([B]);
    expect(m.claimers).toEqual([B]);

    // raise
    const raised = await post(`/api/runs/${runId}/raise`, { personId: A, capCents: 5000 });
    expect(raised.status).toBe(200);
    expect((await getRun(runId)).people.find((p) => p.id === A)!.authorizedCents).toBe(5000);
    process.env.RAISE_CAP = 'off';
    expect((await post(`/api/runs/${runId}/raise`, { personId: A, capCents: 6000 })).status).toBe(403);
    delete process.env.RAISE_CAP;

    // shopper-only
    expect((await post(`/api/runs/${runId}/chips/${eggs.id}/fix`, { personId: B, name: 'Nope' })).status).toBe(403);
    expect((await post(`/api/runs/${runId}/checkout`, { personId: B })).status).toBe(403);

    // checkout, last call, lock
    const co = await post(`/api/runs/${runId}/checkout`, { personId: shopperId });
    expect(co.status).toBe(200);
    await wa.waitFor((x) => x.t === 'lastCall');
    await wa.waitFor((x) => x.t === 'locked');
    await sleep(60);
    wa.send({ t: 'claim', chipId: milk.id });
    expect(await wa.waitFor((x) => x.t === 'error')).toEqual({ t: 'error', reason: 'cart closed' });
    expect(wb.msgs.some((x) => x.t === 'error')).toBe(false);

    // put back the milk, read receipt
    expect((await post(`/api/runs/${runId}/chips/${milk.id}/putback`, { personId: shopperId })).status).toBe(200);
    const rec = await post(`/api/runs/${runId}/receipt`, { imageBase64: '' });
    expect(rec.status).toBe(200);
    expect(rec.body.lines).toHaveLength(3);
    // The put-back milk has no chip to match, so its line stays unmatched.
    expect(rec.body.matches).toHaveLength(2);
    expect(rec.body.unmatchedLines).toEqual([2]);

    const done = await post(`/api/runs/${runId}/confirm`, { personId: shopperId });
    expect(done.status).toBe(200);
    expect(done.body.state).toBe('settled');
    expect(done.body.settle[A].capturedCents).toBe(436);
    expect(done.body.settle[B].capturedCents).toBe(2835);
    expect(done.body.payout.simulated).toBe(true);

    // The milk was put back: only the two shares were captured, and nothing for its 429.
    const captures = payments.calls.filter((c) => c.method === 'capture').map((c) => c.args[1]);
    expect(captures.sort()).toEqual([2835, 436].sort());
    expect(done.body.chips.find((c: { id: string }) => c.id === milk.id).putBack).toBe(true);
    expect(done.body.settle[shopperId]).toBeUndefined();

    // A settled run takes no raise or receipt.
    expect((await post(`/api/runs/${runId}/raise`, { personId: A, capCents: 9000 })).status).toBe(409);
    expect((await post(`/api/runs/${runId}/receipt`, { imageBase64: '' })).status).toBe(409);
    expect((await post(`/api/runs/${runId}/receipt/fix`, { lineIndex: 0, target: 'mine' })).status).toBe(409);
    const late = await post(`/api/runs/${runId}/chips/${milk.id}/fix`, { personId: shopperId, priceCents: 1 });
    expect(late).toEqual({ status: 409, body: { error: 'cart closed' } });

    const calls = payments.calls.length;
    const again = await post(`/api/runs/${runId}/confirm`, { personId: shopperId });
    expect(again.status).toBe(200);
    expect(again.body).toEqual(done.body);
    expect(payments.calls.length).toBe(calls);
  });

  it('back cancels the lock timer', async () => {
    const { runId, shopperId } = await setup();
    await post(`/api/runs/${runId}/checkout`, { personId: shopperId });
    await post(`/api/runs/${runId}/back`, { personId: shopperId });
    await sleep(80);
    expect((await getRun(runId)).state).toBe('open');
  });

  it('serves the qr png and 404s unknown runs', async () => {
    const { runId } = await setup();
    const r = await app.inject({ url: `/api/runs/${runId}/qr` });
    expect(r.headers['content-type']).toContain('image/png');
    expect(r.rawPayload.subarray(1, 4).toString()).toBe('PNG');
    expect((await app.inject({ url: '/api/runs/nope' })).statusCode).toBe(404);
  });

  it('builds the join url from PUBLIC_URL, else the forwarded proto and host', () => {
    expect(qrJoinUrl('r1', { 'x-forwarded-proto': 'https', host: 'dibs.up.railway.app' }, undefined)).toBe('https://dibs.up.railway.app/join?run=r1');
    expect(qrJoinUrl('r1', { host: '192.168.1.5:3000' }, undefined)).toBe('http://192.168.1.5:3000/join?run=r1');
    expect(qrJoinUrl('r1', { 'x-forwarded-proto': 'https,http', host: 'a.test' }, undefined)).toBe('https://a.test/join?run=r1');
    expect(qrJoinUrl('r1', { host: 'ignored' }, 'https://demo.example/')).toBe('https://demo.example/join?run=r1');
  });

  it('reschedules stored last-call runs on boot', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'dibs-boot-'));
    const t = Date.now();
    const past = checkout(seedRun(t), t - 5000, 1000); // ended 4 s ago
    const soon = checkout(seedRun(t), t, 60); // ends in 60 ms
    const later = checkout(seedRun(t), t, 60000);
    writeFileSync(join(dir, 'runs.json'), JSON.stringify({ [past.id]: past, [soon.id]: soon, [later.id]: later }));
    await app.close();
    await start({ dataDir: dir });
    for (let i = 0; i < 50 && (await getRun(soon.id)).state !== 'locked'; i++) await sleep(10);
    expect((await getRun(past.id)).state).toBe('locked');
    expect((await getRun(soon.id)).state).toBe('locked');
    expect((await getRun(later.id)).state).toBe('lastCall');
  });

  it('settles after a restart: the simulator and runs reload from the data dir', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'dibs-restart-'));
    await app.close();
    await start({ dataDir: dir, payments: new SimPayments(dir) });
    const { runId, shopperId, A } = await setup();
    const eggs = (await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint: 'eggs' })).body;
    const wa = connect(runId, A);
    await wa.opened;
    wa.send({ t: 'claim', chipId: eggs.id });
    for (let i = 0; i < 100 && (await getRun(runId)).chips[0].claimers.length === 0; i++) await sleep(10);
    await post(`/api/runs/${runId}/checkout`, { personId: shopperId });
    for (let i = 0; i < 100 && (await getRun(runId)).state !== 'locked'; i++) await sleep(10);
    expect((await post(`/api/runs/${runId}/receipt`, { imageBase64: '' })).status).toBe(200);

    for (const s of sockets.splice(0)) s.terminate();
    await app.close();
    await start({ dataDir: dir, payments: new SimPayments(dir) });
    const done = await post(`/api/runs/${runId}/confirm`, { personId: shopperId });
    expect(done.status).toBe(200);
    expect(done.body.settle[A]).toMatchObject({ step: 'captured', error: null });
    expect(['settled', 'partlySettled']).toContain(done.body.state);
  });

  const nullPriceVision = (fail = false) => {
    const v = new StubVision();
    v.identify = async (): Promise<Identified> => {
      if (fail) throw new Error('boom');
      return { name: 'Mystery Jar', priceCents: null, cropBase64: '', confidence: 1, barcode: null };
    };
    return v;
  };
  const deferredPrice = () => {
    let resolve!: (v: { cents: number; sourceUrl: string } | null) => void;
    const p = new Promise<{ cents: number; sourceUrl: string } | null>((r) => (resolve = r));
    const price: PriceProvider = { lookup: () => p };
    return { price, resolve };
  };

  it('discards a late web price once the chip has a price', async () => {
    const d = deferredPrice();
    await app.close();
    await start({ vision: nullPriceVision(), price: d.price });
    const { runId, shopperId } = await setup();
    const chip = (await post(`/api/runs/${runId}/chips`, { imageBase64: '' })).body;
    await post(`/api/runs/${runId}/chips/${chip.id}/fix`, { personId: shopperId, priceCents: 500 });
    d.resolve({ cents: 999, sourceUrl: 'x' });
    await sleep(30);
    const c = (await getRun(runId)).chips[0];
    expect(c.priceCents).toBe(500);
    expect(c.priceSource).toBe('sticker');
  });

  it('discards a late web price after the run locks, and applies it while open', async () => {
    const d = deferredPrice();
    await app.close();
    await start({ vision: nullPriceVision(), price: d.price });
    const { runId, shopperId } = await setup();
    await post(`/api/runs/${runId}/chips`, { imageBase64: '' });
    await post(`/api/runs/${runId}/checkout`, { personId: shopperId });
    await sleep(80);
    d.resolve({ cents: 999, sourceUrl: 'x' });
    await sleep(30);
    expect((await getRun(runId)).chips[0].priceCents).toBeNull();

    const d2 = deferredPrice();
    await app.close();
    await start({ vision: nullPriceVision(), price: d2.price });
    const r2 = await setup();
    await post(`/api/runs/${r2.runId}/chips`, { imageBase64: '' });
    d2.resolve({ cents: 999, sourceUrl: 'x' });
    await sleep(30);
    const c = (await getRun(r2.runId)).chips[0];
    expect(c.priceCents).toBe(999);
    expect(c.priceSource).toBe('web');
  });

  it('survives a failing snapshot write', async () => {
    const blocker = join(mkdtempSync(join(tmpdir(), 'dibs-')), 'file');
    writeFileSync(blocker, 'x');
    await app.close();
    await start({ dataDir: join(blocker, 'sub') });
    const { runId, A } = await setup();
    const ws = connect(runId, A);
    await ws.opened;
    await ws.waitFor((m) => m.t === 'run');
    const chip = (await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint: 'eggs' })).body;
    ws.send({ t: 'claim', chipId: chip.id });
    await ws.waitFor((m) => m.t === 'run' && (m.run as Run).chips[0]?.claimers.length === 1);
    expect((await getRun(runId)).chips[0].claimers).toEqual([A]);
  });

  it('drops the chip and returns 502 when identify throws', async () => {
    await app.close();
    await start({ vision: nullPriceVision(true) });
    const { runId } = await setup();
    const r = await post(`/api/runs/${runId}/chips`, { imageBase64: '' });
    expect(r.status).toBe(502);
    expect(r.body).toEqual({ error: 'identify failed' });
    expect((await getRun(runId)).chips).toHaveLength(0);
  });

  it('returns 502 when readReceipt throws', async () => {
    const v = new StubVision();
    v.readReceipt = async () => {
      throw new Error('boom');
    };
    await app.close();
    await start({ vision: v });
    const { runId, shopperId } = await setup();
    await post(`/api/runs/${runId}/checkout`, { personId: shopperId });
    await sleep(80);
    const r = await post(`/api/runs/${runId}/receipt`, { imageBase64: '' });
    expect(r.status).toBe(502);
  });

  it('pairs receipt lines with the vision matcher when it has one', async () => {
    const v = new StubVision();
    v.readReceipt = async () => [
      { text: 'DOZ GRADE A LG', cents: 872, quantity: 1 },
      { text: 'BOUNTY SAS', cents: 2399, quantity: 1 },
    ];
    const seen: { lines: unknown[]; chips: { id: string; name: string }[] }[] = [];
    (v as StubVision & { matchReceipt: unknown }).matchReceipt = async (lines: unknown[], chips: { id: string; name: string }[]) => {
      seen.push({ lines, chips });
      const id = (n: string) => chips.find((c) => /eggs/i.test(c.name) === (n === 'eggs'))!.id;
      // One good pair, one with a made-up chip id, one below the confidence floor.
      return [
        { lineIndex: 0, chipId: id('eggs'), confidence: 0.9 },
        { lineIndex: 1, chipId: 'made-up', confidence: 0.9 },
        { lineIndex: 1, chipId: id('towels'), confidence: 0.3 },
      ];
    };
    await app.close();
    await start({ vision: v });
    const { runId, shopperId } = await setup();
    const eggs = (await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint: 'eggs' })).body;
    await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint: 'towels' });
    await post(`/api/runs/${runId}/checkout`, { personId: shopperId });
    await sleep(80);
    const r = await post(`/api/runs/${runId}/receipt`, { imageBase64: '' });
    expect(r.status).toBe(200);
    expect(seen[0].chips).toHaveLength(2);
    expect(r.body.matches).toEqual([{ lineIndex: 0, chipId: eggs.id, confidence: 0.9 }]);
    expect(r.body.unmatchedLines).toEqual([1]);
  });

  it('falls back to the overlap matcher when the vision matcher fails', async () => {
    const v = new StubVision();
    (v as StubVision & { matchReceipt: unknown }).matchReceipt = async () => {
      throw new Error('Gemini HTTP 429');
    };
    await app.close();
    await start({ vision: v });
    const { runId, shopperId } = await setup();
    for (const hint of ['eggs', 'towels', 'milk']) await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint });
    await post(`/api/runs/${runId}/checkout`, { personId: shopperId });
    await sleep(80);
    const r = await post(`/api/runs/${runId}/receipt`, { imageBase64: '' });
    expect(r.status).toBe(200);
    expect(r.body.matches).toHaveLength(3);
    expect(r.body.unmatchedLines).toEqual([]);
  });

  it('refuses receipt while a settle is in flight', async () => {
    class Slow extends SimPayments {
      override async capture(ref: string, authId: string, cents: number) {
        await sleep(150);
        return super.capture(ref, authId, cents);
      }
    }
    const slow = new Slow();
    await app.close();
    await start({ payments: slow });
    const { runId, shopperId, A } = await setup();
    const chip = (await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint: 'eggs' })).body;
    const ws = connect(runId, A);
    await ws.opened;
    ws.send({ t: 'claim', chipId: chip.id });
    await ws.waitFor((m) => m.t === 'run' && (m.run as Run).chips[0]?.claimers.length === 1);
    await post(`/api/runs/${runId}/checkout`, { personId: shopperId });
    await sleep(80);
    await post(`/api/runs/${runId}/receipt`, { imageBase64: '' });
    const confirm = post(`/api/runs/${runId}/confirm`, { personId: shopperId });
    await sleep(40);
    expect((await post(`/api/runs/${runId}/receipt`, { imageBase64: '' })).status).toBe(409);
    expect((await post(`/api/runs/${runId}/receipt/fix`, { lineIndex: 0, target: 'mine' })).status).toBe(409);
    expect((await confirm).status).toBe(200);
  });

  describe('live frames', () => {
    const fx = (n: string) => readFileSync(join(import.meta.dirname, 'fixtures', 'frames', `${n}.jpg`)).toString('base64');
    const seq = [...Array(6).fill('empty'), 'eggs-moving1', 'eggs-moving2', 'eggs-still', 'eggs-still', 'eggs-still'];

    it('relays frames to claimers and turns a settled item into a chip', async () => {
      const { runId, shopperId, A } = await setup();
      const shopper = connect(runId, shopperId);
      const wa = connect(runId, A);
      await Promise.all([shopper.opened, wa.opened]);
      for (let i = 0; i < seq.length; i++) {
        shopper.send({ t: 'frame', jpegBase64: fx(seq[i]), at: i * 500 });
        await sleep(80); // paced so the bounded detector queue does not coalesce frames
      }
      await wa.waitFor((m) => m.t === 'frame');
      await shopper.waitFor((m) => m.t === 'identifying');
      for (let i = 0; i < 200 && !(await getRun(runId)).chips.some((c) => c.state === 'open'); i++) await sleep(10);
      const chip = (await getRun(runId)).chips[0];
      expect(chip.name).toMatch(/Eggs/);
      expect(chip.priceCents).toBe(872);
      expect(shopper.msgs.some((m) => m.t === 'frame')).toBe(false);
      expect(wa.msgs.some((m) => m.t === 'identifying')).toBe(true);
    });

    it('frame with detect false is relayed but not detected', async () => {
      let pushes = 0;
      await app.close();
      await start({ detector: () => ({ push: async () => { pushes++; return []; } }) as never });
      const { runId, shopperId, A } = await setup();
      const shopper = connect(runId, shopperId);
      const wa = connect(runId, A);
      await Promise.all([shopper.opened, wa.opened]);
      shopper.send({ t: 'frame', jpegBase64: fx('empty'), at: 0, detect: false });
      await wa.waitFor((m) => m.t === 'frame');
      await sleep(50);
      expect(pushes).toBe(0);
    });

    it('frame without detect still detects', async () => {
      let pushes = 0;
      await app.close();
      await start({ detector: () => ({ push: async () => { pushes++; return []; } }) as never });
      const { runId, shopperId, A } = await setup();
      const shopper = connect(runId, shopperId);
      const wa = connect(runId, A);
      await Promise.all([shopper.opened, wa.opened]);
      shopper.send({ t: 'frame', jpegBase64: fx('empty'), at: 0 });
      await wa.waitFor((m) => m.t === 'frame');
      await sleep(50);
      expect(pushes).toBe(1);
    });

    it('wisher can delete own wish; others cannot; non-wish chips stay shopper-only', async () => {
      const { runId, shopperId, A, B } = await setup();
      const wa = connect(runId, A);
      const wb = connect(runId, B);
      await Promise.all([wa.opened, wb.opened]);
      const wish = (await post(`/api/runs/${runId}/chips/text`, { name: 'bagels', byPersonId: A })).body;
      const wishId = (wish.chips as { id: string; state: string }[]).find((c) => c.state === 'wish')!.id;
      wb.send({ t: 'remove', chipId: wishId });
      await wb.waitFor((m) => m.t === 'error' && m.reason === 'shopper only');
      expect((await getRun(runId)).chips.some((c) => c.id === wishId)).toBe(true);
      const chip = (await post(`/api/runs/${runId}/chips`, { imageBase64: fx('eggs-still') })).body;
      wa.send({ t: 'remove', chipId: chip.id });
      await wa.waitFor((m) => m.t === 'error' && m.reason === 'shopper only');
      wa.send({ t: 'remove', chipId: wishId });
      for (let i = 0; i < 200 && (await getRun(runId)).chips.some((c) => c.id === wishId); i++) await sleep(10);
      expect((await getRun(runId)).chips.some((c) => c.id === wishId)).toBe(false);
    });

    it('ignores frames from a claimer and after lock', async () => {
      const { runId, shopperId, A } = await setup();
      const shopper = connect(runId, shopperId);
      const wa = connect(runId, A);
      await Promise.all([shopper.opened, wa.opened]);
      wa.send({ t: 'frame', jpegBase64: fx('empty'), at: 0 });
      await sleep(100);
      expect(wa.msgs.some((m) => m.t === 'frame')).toBe(false);
      await post(`/api/runs/${runId}/checkout`, { personId: shopperId });
      await wa.waitFor((m) => m.t === 'locked');
      const n = wa.msgs.length;
      for (let i = 0; i < seq.length; i++) {
        shopper.send({ t: 'frame', jpegBase64: fx(seq[i]), at: i * 500 });
        await sleep(80); // paced so the bounded detector queue does not coalesce frames
      }
      shopper.send({ t: 'identifyAt', x: 100, y: 100 });
      await sleep(300);
      expect(wa.msgs.length).toBe(n);
      expect((await getRun(runId)).chips).toHaveLength(0);
    });

    it('identifies a tap on the latest frame', async () => {
      const { runId, shopperId } = await setup();
      const shopper = connect(runId, shopperId);
      await shopper.opened;
      shopper.send({ t: 'identifyAt', x: 5, y: 5 });
      await sleep(50);
      expect((await getRun(runId)).chips).toHaveLength(0);
      shopper.send({ t: 'frame', jpegBase64: fx('eggs-still'), at: 0 });
      await sleep(50);
      shopper.send({ t: 'identifyAt', x: 5, y: 5 });
      for (let i = 0; i < 200 && (await getRun(runId)).chips.length === 0; i++) await sleep(10);
      for (let i = 0; i < 200 && (await getRun(runId)).chips[0]?.state !== 'open'; i++) await sleep(10);
      const [chip] = (await getRun(runId)).chips;
      expect(chip.state).toBe('open');
      expect(chip.region).toMatchObject({ x: 0, y: 0, w: 200, h: 200 });
    });

    it('retries a failed chip by tapping inside its region, once', async () => {
      await app.close();
      const stub = new StubVision();
      let calls = 0;
      let mode: 'fail' | 'slow' | 'ok' = 'fail';
      const vision = {
        identify: async (...a: Parameters<StubVision['identify']>) => {
          calls++;
          if (mode === 'fail') throw new Error('down');
          if (mode === 'slow') await sleep(300);
          return stub.identify(...a);
        },
        readReceipt: (i: string) => stub.readReceipt(i),
      };
      await start({ vision });
      const { runId, shopperId } = await setup();
      const shopper = connect(runId, shopperId);
      await shopper.opened;
      for (let i = 0; i < seq.length; i++) {
        shopper.send({ t: 'frame', jpegBase64: fx(seq[i]), at: i * 500 });
        await sleep(80); // paced so the bounded detector queue does not coalesce frames
      }
      await shopper.waitFor((m) => m.t === 'error' && m.reason === 'identify failed');
      const [stuck] = (await getRun(runId)).chips;
      expect(stuck.state).toBe('identifying');
      const r = stuck.region!;
      mode = 'slow';
      calls = 0;
      const tap = { t: 'identifyAt', x: r.x + r.w / 2, y: r.y + r.h / 2 };
      shopper.send(tap);
      await sleep(50);
      shopper.send(tap); // in flight: ignored
      for (let i = 0; i < 200 && (await getRun(runId)).chips[0].state !== 'open'; i++) await sleep(10);
      const chips = (await getRun(runId)).chips;
      expect(chips).toHaveLength(1);
      expect(chips[0].id).toBe(stuck.id);
      expect(chips[0].state).toBe('open');
      expect(calls).toBe(1);
    });
  });
});

describe('health', () => {
  it('GET /api/health returns ok', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/health' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true });
  });
});
