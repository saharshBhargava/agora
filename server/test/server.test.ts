import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { AddressInfo } from 'node:net';
import type { FastifyInstance } from 'fastify';
import WebSocket from 'ws';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildServer } from '../src/index.js';
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
});
