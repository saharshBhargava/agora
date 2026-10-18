// Per-person keys and redaction: person ids are public (every snapshot lists them), so only the key
// a person got from create or join may act as them, and no snapshot carries card numbers or auth ids.
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { AddressInfo } from 'node:net';
import type { FastifyInstance } from 'fastify';
import WebSocket from 'ws';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildServer } from '../src/index.js';
import { SimPayments } from '../src/payments/sim.js';
import { AgentPrice } from '../src/price/agent.js';
import { StubPrice } from '../src/price/stub.js';
import { maskPan, publicRun } from '../src/redact.js';
import { seedRun } from '../src/seed.js';
import { StubVision } from '../src/vision/stub.js';
import type { Run } from '../src/types.js';

const card = { number: '4111111111111111', expMonth: 12, expYear: 2030 };
let app: FastifyInstance;
let port: number;
let dataDir: string;
const sockets: WebSocket[] = [];

async function start(over: Partial<Parameters<typeof buildServer>[0]> = {}) {
  dataDir = over.dataDir ?? mkdtempSync(join(tmpdir(), 'dibs-sec-'));
  app = await buildServer({ payments: new SimPayments(), vision: new StubVision(), price: new StubPrice(), lastCallMs: 30, dataDir, ...over });
  await app.listen({ port: 0, host: '127.0.0.1' });
  port = (app.server.address() as AddressInfo).port;
}
beforeEach(() => start());
afterEach(async () => {
  for (const s of sockets.splice(0)) s.terminate();
  await app.close();
});

async function call(method: 'GET' | 'POST', url: string, body?: object, key?: string) {
  const r = await app.inject({ method, url, payload: body, headers: key ? { 'x-dibs-key': key } : {} });
  return { status: r.statusCode, body: r.json(), raw: r.body };
}
const post = (url: string, body: object = {}, key?: string) => call('POST', url, body, key);

/** A run with the shopper and two claimers, Ann and Bo, and an eggs chip. */
async function setup() {
  const created = (await post('/api/runs')).body as { runId: string; shopperId: string; key: string };
  const join1 = (await post(`/api/runs/${created.runId}/join`, { name: 'Ann', card, capCents: 3000 })).body;
  const join2 = (await post(`/api/runs/${created.runId}/join`, { name: 'Bo', card, capCents: 4000 })).body;
  const runId = created.runId;
  const eggs = (await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint: 'eggs' }, created.key)).body;
  return {
    runId, eggs,
    S: { id: created.shopperId, key: created.key },
    A: { id: join1.personId as string, key: join1.key as string },
    B: { id: join2.personId as string, key: join2.key as string },
  };
}

function connect(runId: string, personId: string, key?: string) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?run=${runId}&person=${personId}${key === undefined ? '' : `&key=${encodeURIComponent(key)}`}`);
  sockets.push(ws);
  const msgs: { t: string; [k: string]: unknown }[] = [];
  ws.on('message', (d) => msgs.push(JSON.parse(String(d))));
  const closed = new Promise<{ code: number; reason: string }>((res) => ws.on('close', (code, reason) => res({ code, reason: String(reason) })));
  const waitFor = async (pred: (m: { t: string; [k: string]: unknown }) => boolean) => {
    for (let i = 0; i < 200; i++) {
      const m = msgs.find(pred);
      if (m) return m;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error('timeout waiting for message');
  };
  return { ws, msgs, closed, waitFor, send: (m: object) => ws.send(JSON.stringify(m)) };
}

const NOT_ALLOWED = { error: 'not allowed' };
const SHOPPER_ONLY = { error: 'shopper only' };

describe('keys from create and join', () => {
  it('createRun returns a random shopper id and a key; join returns a key', async () => {
    const one = (await post('/api/runs')).body;
    const two = (await post('/api/runs')).body;
    expect(Object.keys(one).sort()).toEqual(['key', 'runId', 'shopperId']);
    expect(one.shopperId).not.toBe('jake');
    expect(one.shopperId).toMatch(/^[0-9a-f-]{36}$/);
    expect(one.shopperId).not.toBe(two.shopperId);
    expect(one.key).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(one.key).not.toBe(two.key);
    const joined = (await post(`/api/runs/${one.runId}/join`, { name: 'Ann', card, capCents: 3000 })).body;
    expect(joined.key).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(joined.key).not.toBe(one.key);
    // The display name stays the seed's.
    const run = (await call('GET', `/api/runs/${one.runId}`)).body as Run;
    expect(run.people.find((p) => p.id === one.shopperId)?.name).toBe('Jake');
  });

  it('every seeded run gets its own shopper id', () => {
    const ids = new Set(Array.from({ length: 5 }, () => seedRun(0).shopperId));
    expect(ids.size).toBe(5);
    expect(ids.has('jake')).toBe(false);
  });

  it('keys survive a restart', async () => {
    const { runId, S } = await setup();
    await app.close();
    await start({ dataDir });
    expect((await post(`/api/runs/${runId}/checkout`, { personId: S.id }, S.key)).status).toBe(200);
  });
});

describe('REST: only the person\'s own key acts as them', () => {
  it('shopper routes refuse no key, a wrong key, and a claimer pretending to be the shopper', async () => {
    const { runId, eggs, S, A } = await setup();
    const routes: [string, object][] = [
      [`/api/runs/${runId}/chips/${eggs.id}/fix`, { personId: S.id, name: 'Nope' }],
      [`/api/runs/${runId}/chips/${eggs.id}/quantity`, { personId: S.id, quantity: 2 }],
      [`/api/runs/${runId}/chips/${eggs.id}/putback`, { personId: S.id }],
      [`/api/runs/${runId}/checkout`, { personId: S.id }],
      [`/api/runs/${runId}/back`, { personId: S.id }],
      [`/api/runs/${runId}/confirm`, { personId: S.id }],
    ];
    for (const [url, body] of routes) {
      expect(await post(url, body), `${url} no key`).toMatchObject({ status: 403, body: NOT_ALLOWED });
      expect(await post(url, body, 'x'.repeat(43)), `${url} wrong key`).toMatchObject({ status: 403, body: NOT_ALLOWED });
      // Ann's real key, with the shopper's public id in the body.
      expect(await post(url, body, A.key), `${url} impersonation`).toMatchObject({ status: 403, body: NOT_ALLOWED });
      // Ann as herself is still not the shopper.
      expect(await post(url, { ...body, personId: A.id }, A.key), `${url} as claimer`).toMatchObject({ status: 403, body: SHOPPER_ONLY });
    }
    expect((await call('GET', `/api/runs/${runId}`)).body.chips[0]).toMatchObject({ name: eggs.name, quantity: 1, putBack: false });
    expect((await call('GET', `/api/runs/${runId}`)).body.state).toBe('open');
    expect((await post(`/api/runs/${runId}/chips/${eggs.id}/quantity`, { personId: S.id, quantity: 2 }, S.key)).status).toBe(200);
  });

  it('shopper routes without a personId need the shopper\'s key', async () => {
    const { runId, S, A } = await setup();
    for (const key of [undefined, A.key]) {
      const r = await post(`/api/runs/${runId}/chips`, { imageBase64: '', hint: 'milk' }, key);
      expect(r).toMatchObject({ status: 403, body: key ? SHOPPER_ONLY : NOT_ALLOWED });
    }
    expect((await call('GET', `/api/runs/${runId}`)).body.chips).toHaveLength(1);
    await post(`/api/runs/${runId}/checkout`, { personId: S.id }, S.key);
    for (let i = 0; i < 100 && (await call('GET', `/api/runs/${runId}`)).body.state !== 'locked'; i++) await new Promise((r) => setTimeout(r, 10));
    expect(await post(`/api/runs/${runId}/receipt`, { imageBase64: '' })).toMatchObject({ status: 403, body: NOT_ALLOWED });
    expect(await post(`/api/runs/${runId}/receipt`, { imageBase64: '' }, A.key)).toMatchObject({ status: 403, body: SHOPPER_ONLY });
    expect((await post(`/api/runs/${runId}/receipt`, { imageBase64: '' }, S.key)).status).toBe(200);
    expect(await post(`/api/runs/${runId}/receipt/fix`, { lineIndex: 0, target: 'mine' }, A.key)).toMatchObject({ status: 403, body: SHOPPER_ONLY });
    expect(await post(`/api/runs/${runId}/receipt/fix`, { lineIndex: 0, target: 'mine' })).toMatchObject({ status: 403, body: NOT_ALLOWED });
    expect((await post(`/api/runs/${runId}/receipt/fix`, { lineIndex: 0, target: 'mine' }, S.key)).status).toBe(200);
  });

  it('a claimer can raise, wish and read wish picks only as themself', async () => {
    const { runId, A, B } = await setup();
    expect(await post(`/api/runs/${runId}/raise`, { personId: B.id, capCents: 9000 }, A.key)).toMatchObject({ status: 403, body: NOT_ALLOWED });
    expect(await post(`/api/runs/${runId}/raise`, { personId: B.id, capCents: 9000 })).toMatchObject({ status: 403, body: NOT_ALLOWED });
    expect((await call('GET', `/api/runs/${runId}`)).body.people.find((p: { id: string }) => p.id === B.id).authorizedCents).toBe(4000);
    expect((await post(`/api/runs/${runId}/raise`, { personId: B.id, capCents: 5000 }, B.key)).status).toBe(200);

    expect(await post(`/api/runs/${runId}/chips/text`, { name: 'Bagels', byPersonId: B.id }, A.key)).toMatchObject({ status: 403, body: NOT_ALLOWED });
    expect(await post(`/api/runs/${runId}/chips/text`, { name: 'Bagels', byPersonId: B.id })).toMatchObject({ status: 403, body: NOT_ALLOWED });
    const wished = await post(`/api/runs/${runId}/chips/text`, { name: 'Bagels', byPersonId: A.id }, A.key);
    expect(wished.status).toBe(200);
    expect(wished.body.chips.find((c: { name: string }) => c.name === 'Bagels').wishedBy).toBe(A.id);

    const picks = `/api/runs/${runId}/wish-picks?personId=${B.id}`;
    expect(await call('GET', picks)).toMatchObject({ status: 403, body: NOT_ALLOWED });
    expect(await call('GET', picks, undefined, A.key)).toMatchObject({ status: 403, body: NOT_ALLOWED });
    expect((await call('GET', picks, undefined, B.key)).status).toBe(200);
  });

  it('a key from another run does not work here', async () => {
    const one = await setup();
    const two = await setup();
    expect(await post(`/api/runs/${one.runId}/checkout`, { personId: one.S.id }, two.S.key)).toMatchObject({ status: 403, body: NOT_ALLOWED });
  });
});

describe('WebSocket: connecting needs the person\'s key', () => {
  it('closes 1008 without a key, with a wrong key, or with someone else\'s key', async () => {
    const { runId, S, A, B } = await setup();
    for (const [person, key] of [[S.id, undefined], [S.id, 'nope'], [S.id, A.key], [B.id, A.key]] as const) {
      const c = connect(runId, person, key);
      expect(await c.closed).toEqual({ code: 1008, reason: 'not allowed' });
      expect(c.msgs).toEqual([]);
    }
  });

  it('a claimer cannot act as the shopper over the socket', async () => {
    const { runId, eggs, S, A } = await setup();
    const fake = connect(runId, S.id, A.key);
    await fake.closed;
    const real = connect(runId, A.id, A.key);
    await real.waitFor((m) => m.t === 'run');
    real.send({ t: 'remove', chipId: eggs.id });
    await real.waitFor((m) => m.t === 'error' && m.reason === 'shopper only');
    real.send({ t: 'claim', chipId: eggs.id });
    await real.waitFor((m) => m.t === 'run' && (m.run as Run).chips[0].claimers.includes(A.id));
    const shopper = connect(runId, S.id, S.key);
    await shopper.waitFor((m) => m.t === 'run');
    shopper.send({ t: 'remove', chipId: eggs.id });
    await real.waitFor((m) => m.t === 'run' && (m.run as Run).chips[0].state === 'removed');
  });
});

describe('runs from before keys', () => {
  it('are refused with a message to start a new run', async () => {
    const old = seedRun(Date.now());
    const withClaimer: Run = { ...old, people: [...old.people, { id: 'priya', name: 'Priya', initial: 'P', isShopper: false, authorizedCents: 4000, authId: 'a1', approvalCode: '888888', payoutPan: null }] };
    const dir = mkdtempSync(join(tmpdir(), 'dibs-old-'));
    writeFileSync(join(dir, 'runs.json'), JSON.stringify({ [old.id]: withClaimer }));
    await app.close();
    await start({ dataDir: dir });
    const OLD = { error: 'This run was started before an update. Start a new run.' };
    expect(await post(`/api/runs/${old.id}/checkout`, { personId: old.shopperId })).toMatchObject({ status: 410, body: OLD });
    expect(await post(`/api/runs/${old.id}/chips/text`, { name: 'Milk', byPersonId: 'priya' }, 'anything')).toMatchObject({ status: 410, body: OLD });
    expect(await post(`/api/runs/${old.id}/join`, { name: 'Ann', card, capCents: 3000 })).toMatchObject({ status: 410, body: OLD });
    const c = connect(old.id, 'priya', 'anything');
    expect(await c.closed).toEqual({ code: 1008, reason: 'old run' });
    // Reading it still works, redacted.
    const run = (await call('GET', `/api/runs/${old.id}`)).body as Run;
    expect(run.people.find((p) => p.id === 'priya')?.authId).toBeNull();
  });
});

describe('redaction', () => {
  it('maskPan keeps the last four', () => {
    expect(maskPan('4111111111111111')).toBe('•••• 1111');
    expect(maskPan(null)).toBeNull();
    expect(maskPan('12')).toBe('•••• 12');
  });

  it('publicRun nulls auth ids and masks card numbers without touching the stored run', () => {
    const r = seedRun(0);
    const stored: Run = {
      ...r,
      people: [...r.people, { id: 'p', name: 'P', initial: 'P', isShopper: false, authorizedCents: 1, authId: 'auth-1', approvalCode: '888888', payoutPan: null }],
      payout: { simulated: true, businessApplicationId: 'FD', amountCents: 5, recipientPan: '4111111111111111', requestId: 'q' },
    };
    const out = publicRun(stored);
    expect(out.people.map((p) => [p.authId, p.payoutPan])).toEqual([[null, '•••• 1111'], [null, null]]);
    expect(out.people[1].approvalCode).toBe('888888');
    expect(out.payout?.recipientPan).toBe('•••• 1111');
    expect(stored.people[1].authId).toBe('auth-1');
    expect(stored.payout?.recipientPan).toBe('4111111111111111');
  });

  it('REST and WebSocket snapshots carry no PAN, auth id or key, through settle', async () => {
    const { runId, eggs, S, A, B } = await setup();
    const leaks = (text: string) => {
      expect(text).not.toContain('4111111111111111');
      for (const k of [S.key, A.key, B.key]) expect(text).not.toContain(k);
      expect(text).not.toMatch(/"authId":"/);
    };
    const wa = connect(runId, A.id, A.key);
    const raw: string[] = [];
    wa.ws.on('message', (d) => raw.push(String(d)));
    await wa.waitFor((m) => m.t === 'run');
    wa.send({ t: 'claim', chipId: eggs.id });
    await wa.waitFor((m) => m.t === 'run' && (m.run as Run).chips[0].claimers.length === 1);
    const shopperView = (await call('GET', `/api/runs/${runId}`)).body as Run;
    expect(shopperView.people.find((p) => p.id === S.id)?.payoutPan).toBe('•••• 1111');
    leaks((await call('GET', `/api/runs/${runId}`)).raw);

    await post(`/api/runs/${runId}/checkout`, { personId: S.id }, S.key);
    for (let i = 0; i < 100 && (await call('GET', `/api/runs/${runId}`)).body.state !== 'locked'; i++) await new Promise((r) => setTimeout(r, 10));
    await post(`/api/runs/${runId}/receipt`, { imageBase64: '' }, S.key);
    const done = await post(`/api/runs/${runId}/confirm`, { personId: S.id }, S.key);
    expect(done.status).toBe(200);
    expect(done.body.payout.recipientPan).toBe('•••• 1111');
    leaks(done.raw);
    leaks((await call('GET', `/api/runs/${runId}`)).raw);
    await wa.waitFor((m) => m.t === 'run' && (m.run as Run).payout !== null);
    expect(raw.length).toBeGreaterThan(2);
    for (const m of raw) leaks(m);
  });
});

describe('price requests belong to one run and its shopper', () => {
  async function withAgent() {
    const agent = new AgentPrice();
    await app.close();
    await start({ agent, price: agent });
    return agent;
  }

  it('lists only that run\'s open lookups, for its shopper key', async () => {
    const agent = await withAgent();
    const one = await setup();
    const two = await setup();
    void agent.lookup('Oat milk', 'QFC', one.runId);
    void agent.lookup('Bananas', 'QFC', two.runId);
    const list = (key?: string, run?: string) =>
      app.inject({ url: '/api/price-requests?open=1', headers: { ...(key ? { 'x-dibs-key': key } : {}), ...(run ? { 'x-dibs-run': run } : {}) } });
    expect((await list()).statusCode).toBe(403);
    expect((await list(undefined, one.runId)).statusCode).toBe(403);
    expect((await list(one.A.key, one.runId)).statusCode).toBe(403);
    expect((await list(two.S.key, one.runId)).statusCode).toBe(403);
    expect((await list(one.S.key, 'nope')).statusCode).toBe(404);
    const mine = (await list(one.S.key, one.runId)).json();
    expect(mine.map((r: { name: string }) => r.name)).toContain('Oat milk');
    expect(mine.map((r: { name: string }) => r.name)).not.toContain('Bananas');
  });

  it('answers a lookup only with the shopper key of the lookup\'s run', async () => {
    const agent = await withAgent();
    const one = await setup();
    const two = await setup();
    const p = agent.lookup('Oat milk', 'QFC', one.runId);
    const id = agent.open(one.runId).find((r) => r.name === 'Oat milk')!.id;
    const page = { pageText: '1 results\n$4.99\nOat Milk' };
    const extract = (key?: string) => app.inject({ method: 'POST', url: `/api/price-requests/${id}/extract`, payload: page, headers: key ? { 'x-dibs-key': key } : {} });
    const step = (key?: string) => app.inject({ method: 'POST', url: `/api/price-requests/${id}/agent-step`, payload: { contents: [] }, headers: key ? { 'x-dibs-key': key } : {} });
    for (const key of [undefined, one.A.key, two.S.key]) {
      expect((await extract(key)).statusCode).toBe(403);
      expect((await step(key)).statusCode).toBe(403);
    }
    expect(agent.get(id)).toBeDefined();
    process.env.PRICE_DIRECT_POST = '1';
    try {
      const direct = (key?: string) => app.inject({ method: 'POST', url: `/api/price-requests/${id}`, payload: { cents: 1, url: 'https://www.qfc.com/x' }, headers: key ? { 'x-dibs-key': key } : {} });
      expect((await direct(two.S.key)).statusCode).toBe(403);
      expect((await direct(one.S.key)).statusCode).toBe(200);
    } finally {
      delete process.env.PRICE_DIRECT_POST;
    }
    expect((await p)?.cents).toBe(1);
  });

  it('a price found for one run is not reused by another run', async () => {
    const agent = new AgentPrice({ timeoutMs: 50 });
    const first = agent.lookup('Oat milk', 'QFC', 'run-a');
    agent.resolve(agent.open('run-a')[0].id, { cents: 1, url: 'https://www.qfc.com/x' });
    expect((await first)?.cents).toBe(1);
    expect((await agent.lookup('oat milk', 'qfc', 'run-a'))?.cents).toBe(1);
    const other = agent.lookup('Oat milk', 'QFC', 'run-b');
    expect(agent.open('run-b')).toHaveLength(1);
    expect(await other).toBeNull();
  });
});
