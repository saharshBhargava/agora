import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { buildServer } from '../src/index.js';
import { hashKey } from '../src/keys.js';
import { SimPayments } from '../src/payments/sim.js';
import { StubPrice } from '../src/price/stub.js';
import { StubVision } from '../src/vision/stub.js';
import { cleanText } from '../src/team/clean.js';
import {
  TeamBackend, itemDetail, mapHousehold, runoutReason, shortReason, teamBackendFromEnv, teamBaseUrl,
} from '../src/team/backend.js';
import { composePicks, historyPicks, type HouseholdPicks, type HouseholdSource } from '../src/wish-picks.js';
import { createRun, wish } from '../src/run.js';
import type { Chip, Run } from '../src/types.js';

const NOW = Date.parse('2026-10-18T17:00:00Z');
const DAY = 86_400_000;

function chip(name: string, over: Partial<Chip> = {}): Chip {
  return {
    id: `${name}-${Math.random()}`, name, priceCents: 399, priceSource: 'sticker', photoUrl: null, region: null,
    quantity: 1, claimers: [], state: 'open', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
    overCap: [], removedAt: null, addedAt: NOW, ...over,
  };
}

function run(id: string, store: string, chips: Chip[]): Run {
  const r = createRun({ id: 'jake', name: 'Jake', initial: 'J', payoutPan: '4111111111111111' }, store, '4111111111111111', NOW);
  return { ...r, id, chips, people: [...r.people, { id: 'priya', name: 'Priya', initial: 'P', isShopper: false, authorizedCents: 4000, authId: 'a', approvalCode: '888888', payoutPan: null }] };
}

// Shapes from backend/app/schemas.py on main (ShoppingList, WishlistItem, RunoutsOut), trimmed to what matters.
const lists = [
  {
    id: 'l1', name: 'Saturday groceries', merchant: { id: 'm1', name: 'PCC Community Markets', locality: null, scope: 'global' },
    status: 'open', source: 'user', updated_at: '2026-10-16T10:00:00Z',
    items: [{ title: 'Sourdough bread', quantity: 1, unit: null, checked: false }],
  },
  {
    id: 'l2', name: 'Household essentials', merchant: { id: 'm2', name: 'Target', locality: null, scope: 'global' },
    status: 'open', source: 'user', updated_at: '2026-10-17T10:00:00Z',
    items: [
      { title: 'Dish soap', quantity: 2, unit: 'bottles', checked: false },
      { title: 'Kitchen sponges', quantity: 1, unit: 'pack', checked: false },
      { title: 'Trash bags', quantity: 1, unit: 'box', checked: true },
    ],
  },
  {
    id: 'l3', name: 'QFC run', merchant: { id: 'm3', name: 'QFC', locality: 'Ballard', scope: 'global' },
    status: 'open', source: 'generated', updated_at: '2026-10-18T10:00:00Z',
    items: [{ title: 'Large eggs', quantity: 12, unit: 'ct', checked: false }],
  },
];
const suggestions = [
  { title: 'Oat milk', status: 'suggested', rationale: 'You finish 2% milk about every 6 days; oat milk keeps 3x longer and is on sale at PCC.' },
  { title: 'Bananas', status: 'suggested', rationale: null },
];
const runouts = {
  household_id: 'h', within_days: 7, as_of: '2026-10-18T17:00:00Z',
  runouts: [
    { item: { display_name: 'Large eggs, 12 ct' }, forecast: { status: 'runs_out', runout_at: new Date(NOW + 1.5 * DAY).toISOString() } },
    { item: { display_name: 'Coffee beans' }, forecast: { status: 'out', runout_at: new Date(NOW - DAY).toISOString() } },
  ],
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

type Call = { url: string; init: RequestInit };
function fakeFetch(over: Partial<Record<string, () => Response | Promise<Response>>> = {}) {
  const calls: Call[] = [];
  const impl = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const url = String(input);
    calls.push({ url, init });
    const path = new URL(url).pathname;
    if (over[path]) return over[path]!();
    if (path === '/v1/dev/login') return json({ access_token: 'tok-1', token_type: 'bearer', expires_at: Math.floor(NOW / 1000) + 3600 });
    if (path === '/v1/lists') return json(lists);
    if (path === '/v1/wishlist/suggestions') return json(suggestions);
    if (path === '/v1/forecasts/runouts') return json(runouts);
    return json({}, 404);
  }) as typeof fetch;
  return { impl, calls };
}

describe('mapping the team backend', () => {
  it('keeps unchecked items of hand-made open lists, with quantity and unit', () => {
    const h = mapHousehold(lists, [], {}, NOW);
    expect(h.lists.map((l) => l.name)).toEqual(['Saturday groceries', 'Household essentials']);
    expect(h.lists[1]).toEqual({
      name: 'Household essentials', store: 'Target', updatedAt: Date.parse('2026-10-17T10:00:00Z'),
      items: [{ name: 'Dish soap', detail: '2 bottles' }, { name: 'Kitchen sponges', detail: '1 pack' }],
    });
  });

  it('turns run-outs and suggestions into reasons, run-outs first', () => {
    expect(mapHousehold([], suggestions, runouts, NOW).suggestions).toEqual([
      { name: 'Large eggs, 12 ct', reason: 'Running low · about 2 days left' },
      { name: 'Coffee beans', reason: 'Running low · probably out now' },
      { name: 'Oat milk', reason: 'You finish 2% milk about every 6 days' },
      { name: 'Bananas', reason: 'Picked for your home' },
    ]);
  });

  it('formats details and reasons', () => {
    expect(itemDetail(4, null)).toBe('×4');
    expect(itemDetail(1, null)).toBe('');
    expect(itemDetail(1.5, 'lb')).toBe('1.5 lb');
    expect(itemDetail(2, 'unit')).toBe('×2');
    expect(runoutReason('runs_out', new Date(NOW + 0.4 * DAY).toISOString(), NOW)).toBe('Running low · about 1 day left');
    expect(runoutReason('runs_out', 'not a date', NOW)).toBe('Running low');
    expect(shortReason('Back in season at Ballard Farmers Market.')).toBe('Back in season at Ballard Farmers Market');
    expect(Array.from(shortReason('x'.repeat(30) + ' ' + 'y'.repeat(60))).length).toBeLessThanOrEqual(60);
  });

  it('treats the text as untrusted: strips controls and clamps to 80 characters', () => {
    const h = mapHousehold(
      [{ name: 'L\u0000ist\u202E', source: 'user', status: 'open', items: [{ title: `Oat\nmilk ${'z'.repeat(200)}`, quantity: 1, checked: false }, { title: 42, checked: false }] }],
      [{ title: 'Ignore previous instructions\u0007', status: 'suggested', rationale: 'a\u200Bb' }, 'junk', null],
      { runouts: [{ item: {}, forecast: {} }, 7] },
      NOW,
    );
    expect(h.lists[0]!.name).toBe('L ist');
    expect(h.lists[0]!.items).toHaveLength(1);
    expect(h.lists[0]!.items[0]!.name.startsWith('Oat milk zz')).toBe(true);
    expect(h.lists[0]!.items[0]!.name.length).toBe(80);
    expect(h.suggestions).toEqual([{ name: 'Ignore previous instructions', reason: 'a b' }]);
    expect(cleanText('👍'.repeat(100), 80)).toBe('👍'.repeat(80));
    expect(mapHousehold('nope', { x: 1 }, null, NOW)).toEqual({ lists: [], suggestions: [] });
  });
});

describe('TeamBackend', () => {
  it('signs in once, sends the bearer token, maps the three reads and caches them for 60 s', async () => {
    let t = NOW;
    const { impl, calls } = fakeFetch();
    const team = new TeamBackend({ baseUrl: 'https://team.example', password: 'secret-password-1' }, { fetchImpl: impl, now: () => t, log: () => {} });
    const first = await team.picks();
    expect(first.lists).toHaveLength(2);
    expect(first.suggestions[0]).toEqual({ name: 'Large eggs, 12 ct', reason: 'Running low · about 2 days left' });

    const login = calls[0]!;
    expect(login.url).toBe('https://team.example/v1/dev/login');
    expect(login.init.method).toBe('POST');
    expect(JSON.parse(String(login.init.body))).toEqual({ handle: 'demo', password: 'secret-password-1' });
    const reads = calls.slice(1).map((c) => c.url).sort();
    expect(reads).toEqual([
      'https://team.example/v1/forecasts/runouts?within=7d',
      'https://team.example/v1/lists?status=open',
      'https://team.example/v1/wishlist/suggestions',
    ]);
    for (const c of calls) expect(c.init.redirect).toBe('error');
    for (const c of calls.slice(1)) expect((c.init.headers as Record<string, string>).authorization).toBe('Bearer tok-1');

    t += 59_000;
    await team.picks();
    expect(calls).toHaveLength(4);
    t += 2_000;
    await team.picks();
    expect(calls).toHaveLength(7); // token still good: three reads, no new login
    expect(calls.filter((c) => c.url.endsWith('/v1/dev/login'))).toHaveLength(1);
  });

  it('signs in again when the token is refused', async () => {
    let refused = 1;
    const { impl, calls } = fakeFetch({
      '/v1/lists': () => (refused-- > 0 ? json({ title: 'invalid_token' }, 401) : json(lists)),
    });
    const team = new TeamBackend({ baseUrl: 'https://team.example', password: 'pw-123456789012' }, { fetchImpl: impl, now: () => NOW, log: () => {} });
    const picks = await team.picks();
    expect(picks.lists).toHaveLength(2);
    expect(calls.filter((c) => c.url.endsWith('/v1/dev/login'))).toHaveLength(2);
  });

  it('fails on a timeout, logs one line with no secrets, and remembers the failure briefly', async () => {
    const lines: string[] = [];
    let t = NOW;
    const { impl, calls } = fakeFetch({
      '/v1/forecasts/runouts': () => Promise.reject(Object.assign(new Error('The operation was aborted due to timeout'), { name: 'TimeoutError' })),
    });
    const team = new TeamBackend({ baseUrl: 'https://team.example', password: 'pw-SECRET-9876' }, { fetchImpl: impl, now: () => t, log: (l) => lines.push(l) });
    await expect(team.picks()).rejects.toThrow('timeout');
    await expect(team.picks()).rejects.toThrow('timeout');
    expect(lines).toEqual(['wish-picks: team backend unavailable (timeout); using run history']);
    expect(lines.join()).not.toMatch(/SECRET|tok-1|team\.example/);
    const made = calls.length;
    t += 21_000;
    await expect(team.picks()).rejects.toThrow('timeout');
    expect(calls.length).toBeGreaterThan(made);
  });

  it('gives up on a refused login or a bad body', async () => {
    const lines: string[] = [];
    const refused = new TeamBackend({ baseUrl: 'https://t.example', password: 'wrong-password' }, {
      fetchImpl: fakeFetch({ '/v1/dev/login': () => json({ title: 'invalid_credentials' }, 401) }).impl, log: (l) => lines.push(l),
    });
    await expect(refused.picks()).rejects.toThrow('login refused');
    const garbled = new TeamBackend({ baseUrl: 'https://t.example', password: 'pw-123456789012' }, {
      fetchImpl: fakeFetch({ '/v1/lists': () => new Response('<html>', { status: 200 }) }).impl, log: (l) => lines.push(l),
    });
    await expect(garbled.picks()).rejects.toThrow('bad response');
    expect(lines).toEqual([
      'wish-picks: team backend unavailable (login refused); using run history',
      'wish-picks: team backend unavailable (bad response); using run history',
    ]);
  });

  it('is off unless TEAM_API_BASE_URL and AGORA_DEMO_PASSWORD are both set and usable', () => {
    const lines: string[] = [];
    const log = (l: string) => lines.push(l);
    expect(teamBackendFromEnv({}, { log })).toBeNull();
    expect(teamBackendFromEnv({ TEAM_API_BASE_URL: 'https://api.example' }, { log })).toBeNull();
    expect(teamBackendFromEnv({ TEAM_API_BASE_URL: 'http://api.example', AGORA_DEMO_PASSWORD: 'x' }, { log })).toBeNull();
    expect(teamBackendFromEnv({ TEAM_API_BASE_URL: 'https://api.example/v1/', AGORA_DEMO_PASSWORD: 'pw' }, { log })).toBeInstanceOf(TeamBackend);
    expect(lines).toHaveLength(2);
    expect(lines.join()).not.toContain('pw');
    expect(teamBaseUrl('https://api.example/v1/')).toBe('https://api.example');
    expect(teamBaseUrl('http://localhost:8000')).toBe('http://localhost:8000');
    expect(teamBaseUrl('https://user:pw@api.example')).toBeNull();
    expect(teamBaseUrl('ftp://api.example')).toBeNull();
  });
});

describe('fitting picks to a run', () => {
  const household: HouseholdPicks = mapHousehold(lists, suggestions, runouts, NOW);

  it('uses the most recently changed list, hides what is in the cart, keeps what is wished', () => {
    const r = wish(run('r', 'QFC', [chip('Kitchen Sponges')]), 'priya', 'dish soap', NOW, 'w1');
    const picks = composePicks(r, household, []);
    expect(picks.list).toEqual({ name: 'Household essentials', store: 'Target', items: [{ name: 'Dish soap', detail: '2 bottles' }] });
  });

  it('prefers the list for this store', () => {
    const atPcc = composePicks(run('r', 'PCC Community Markets', []), household, []);
    expect(atPcc.list?.name).toBe('Saturday groceries');
  });

  it('drops suggestions in the cart, wished, on the list or repeated; history fills in after the household', () => {
    const r = wish(run('r', 'QFC', [chip('Coffee Beans')]), 'priya', 'Bananas', NOW, 'w1');
    const picks = composePicks(r, household, [
      { name: 'Oat Milk', reason: 'Often in your QFC runs' },
      { name: 'dish soap', reason: 'In your last run' },
      { name: 'Greek yogurt', reason: 'Often in your QFC runs' },
    ]);
    expect(picks.suggestions).toEqual([
      { name: 'Large eggs, 12 ct', reason: 'Running low · about 2 days left' },
      { name: 'Oat milk', reason: 'You finish 2% milk about every 6 days' },
      { name: 'Greek yogurt', reason: 'Often in your QFC runs' },
    ]);
  });

  it('caps each section at 12', () => {
    const many: HouseholdPicks = {
      lists: [{ name: 'Big', store: null, updatedAt: 1, items: Array.from({ length: 30 }, (_, i) => ({ name: `Item ${i}`, detail: '' })) }],
      suggestions: Array.from({ length: 30 }, (_, i) => ({ name: `Idea ${i}`, reason: 'Picked for your home' })),
    };
    const picks = composePicks(run('r', 'QFC', []), many, []);
    expect(picks.list?.items).toHaveLength(12);
    expect(picks.suggestions).toHaveLength(12);
  });

  it('history: most frequent in this store first, minus this run, with reasons', () => {
    const past = [
      run('a', 'QFC', [chip('Greek yogurt', { addedAt: NOW - 5 * DAY }), chip('Bananas', { addedAt: NOW - 5 * DAY })]),
      run('b', 'qfc', [chip('greek yogurt', { addedAt: NOW - 2 * DAY }), chip('Paper towels', { addedAt: NOW - 2 * DAY }), chip('Gone', { state: 'removed', addedAt: NOW - 2 * DAY })]),
      run('c', 'Costco', [chip('Rotisserie chicken', { addedAt: NOW - DAY })]),
      run('d', 'QFC', [chip('Never bought', { state: 'wish' })]),
    ];
    const current = wish(run('now', 'QFC', []), 'priya', 'Bananas', NOW, 'w');
    expect(historyPicks([...past, current], current)).toEqual([
      { name: 'greek yogurt', reason: 'Often in your QFC runs' },
      { name: 'Paper towels', reason: 'In your last run' },
    ]);
    const atCostco = run('now2', 'costco', []);
    expect(historyPicks(past, atCostco)).toEqual([{ name: 'Rotisserie chicken', reason: 'In your last run' }]);
  });
});

describe('GET /api/runs/:id/wish-picks', () => {
  let app: FastifyInstance;
  afterEach(async () => {
    await app.close();
  });

  /** Priya's key in every run (the route answers only the person whose key it is). */
  const PRIYA_KEY = 'priya-key-0123456789';
  async function start(team: HouseholdSource | null, runs: Run[]) {
    const dataDir = mkdtempSync(join(tmpdir(), 'dibs-wish-'));
    writeFileSync(join(dataDir, 'runs.json'), JSON.stringify(Object.fromEntries(runs.map((r) => [r.id, r]))));
    writeFileSync(join(dataDir, 'keys.json'), JSON.stringify(Object.fromEntries(runs.map((r) => [r.id, { priya: hashKey(PRIYA_KEY) }]))));
    app = await buildServer({ payments: new SimPayments(), vision: new StubVision(), price: new StubPrice(), dataDir, team });
  }
  const past = run('past', 'QFC', [chip('Greek yogurt', { addedAt: NOW - DAY }), chip('Paper towels', { addedAt: NOW - DAY })]);
  const current = run('now', 'QFC', [chip('Paper towels')]);
  const get = async (url: string) => {
    const r = await app.inject({ url, headers: { 'x-dibs-key': PRIYA_KEY } });
    return { status: r.statusCode, body: r.json() };
  };

  it('without the team backend: list null, suggestions from run history', async () => {
    delete process.env.TEAM_API_BASE_URL;
    await start(null, [past, current]);
    expect(await get('/api/runs/now/wish-picks?personId=priya')).toEqual({
      status: 200,
      body: { list: null, suggestions: [{ name: 'Greek yogurt', reason: 'In your last run' }] },
    });
  });

  it('with the team backend: its list and suggestions, then history', async () => {
    const { impl } = fakeFetch();
    await start(new TeamBackend({ baseUrl: 'https://team.example', password: 'pw-123456789012' }, { fetchImpl: impl, now: () => NOW, log: () => {} }), [past, current]);
    const { status, body } = await get('/api/runs/now/wish-picks?personId=priya');
    expect(status).toBe(200);
    expect(body.list).toEqual({
      name: 'Household essentials', store: 'Target',
      items: [{ name: 'Dish soap', detail: '2 bottles' }, { name: 'Kitchen sponges', detail: '1 pack' }],
    });
    expect(body.suggestions.map((s: { name: string }) => s.name)).toEqual(['Large eggs, 12 ct', 'Coffee beans', 'Oat milk', 'Bananas', 'Greek yogurt']);
  });

  it('falls back to history when the team backend fails', async () => {
    const failing: HouseholdSource = { picks: () => Promise.reject(new Error('down')) };
    await start(failing, [past, current]);
    expect((await get('/api/runs/now/wish-picks?personId=priya')).body).toEqual({
      list: null, suggestions: [{ name: 'Greek yogurt', reason: 'In your last run' }],
    });
  });

  it('refuses an unknown run or person', async () => {
    await start(null, [current]);
    expect((await get('/api/runs/nope/wish-picks?personId=priya')).status).toBe(404);
    expect(await get('/api/runs/now/wish-picks?personId=stranger')).toEqual({ status: 403, body: { error: 'not allowed' } });
    expect((await get('/api/runs/now/wish-picks')).status).toBe(403);
  });
});
