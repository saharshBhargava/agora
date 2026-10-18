import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { inspect } from 'node:util';
import type { FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { buildServer } from '../src/index.js';
import { hashKey } from '../src/keys.js';
import { SimPayments } from '../src/payments/sim.js';
import { StubPrice } from '../src/price/stub.js';
import { StubVision } from '../src/vision/stub.js';
import { cleanText } from '../src/team/clean.js';
import {
  TeamBackend, householdToken, itemDetail, mapHousehold, runoutReason, shortReason, teamBackendFromEnv, teamBaseUrl,
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

  it('is off unless TEAM_API_BASE_URL is set and usable; AGORA_DEMO_PASSWORD is optional', () => {
    const lines: string[] = [];
    const log = (l: string) => lines.push(l);
    expect(teamBackendFromEnv({}, { log })).toBeNull();
    expect(teamBackendFromEnv({ TEAM_API_BASE_URL: 'http://api.example', AGORA_DEMO_PASSWORD: 'x' }, { log })).toBeNull();
    expect(teamBackendFromEnv({ TEAM_API_BASE_URL: 'https://api.example' }, { log })).toBeInstanceOf(TeamBackend);
    expect(teamBackendFromEnv({ TEAM_API_BASE_URL: 'https://api.example/v1/', AGORA_DEMO_PASSWORD: 'pw' }, { log })).toBeInstanceOf(TeamBackend);
    expect(lines).toHaveLength(1);
    expect(lines.join()).not.toContain('pw');
    expect(teamBaseUrl('https://api.example/v1/')).toBe('https://api.example');
    expect(teamBaseUrl('http://localhost:8000')).toBe('http://localhost:8000');
    expect(teamBaseUrl('https://user:pw@api.example')).toBeNull();
    expect(teamBaseUrl('ftp://api.example')).toBeNull();
  });
});

// ---- the signed-in person's own household (X-Household-Token) ----

const TOK_A = 'tok-AAAAAAAAAAAAAAAAAAAAAAAA';
const TOK_B = 'tok-BBBBBBBBBBBBBBBBBBBBBBBB';

type Household = { lists: unknown; suggestions: unknown; runouts: unknown };
/** A household whose every name carries `tag`, so one person's answer can't be mistaken for another's. */
function householdOf(tag: string): Household {
  return {
    lists: [{
      id: `l-${tag}`, name: `${tag} groceries`, merchant: { id: 'm', name: 'QFC', locality: null, scope: 'global' },
      status: 'open', source: 'user', updated_at: '2026-10-17T10:00:00Z',
      items: [{ title: `${tag} milk`, quantity: 1, unit: null, checked: false }],
    }],
    suggestions: [{ title: `${tag} granola`, status: 'suggested', rationale: `${tag} finishes it every week.` }],
    runouts: { runouts: [{ item: { display_name: `${tag} eggs` }, forecast: { status: 'runs_out', runout_at: new Date(NOW + DAY).toISOString() } }] },
  };
}
const demoHousehold: Household = { lists, suggestions, runouts };

/**
 * A team API where each bearer token has its own household. `tokens` maps token to household; any other
 * bearer gets 401 (or `refuse`'s status). Dev login hands out `tok-demo`, the demo household's token.
 */
function bearerFetch(tokens: Record<string, Household>, refuse = 401) {
  const calls: Call[] = [];
  const all: Record<string, Household> = { 'tok-demo': demoHousehold, ...tokens };
  const impl = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const url = String(input);
    calls.push({ url, init });
    const path = new URL(url).pathname;
    if (path === '/v1/dev/login') return json({ access_token: 'tok-demo', token_type: 'bearer', expires_at: Math.floor(NOW / 1000) + 3600 });
    const bearer = String((init.headers as Record<string, string> | undefined)?.authorization ?? '').replace(/^Bearer /, '');
    const h = all[bearer];
    if (!h) return json({ title: 'invalid_token' }, refuse);
    if (path === '/v1/lists') return json(h.lists);
    if (path === '/v1/wishlist/suggestions') return json(h.suggestions);
    if (path === '/v1/forecasts/runouts') return json(h.runouts);
    return json({}, 404);
  }) as typeof fetch;
  const logins = () => calls.filter((c) => c.url.endsWith('/v1/dev/login')).length;
  return { impl, calls, logins };
}

describe('the person\'s own household token', () => {
  const bearerOf = (c: Call) => (c.init.headers as Record<string, string>).authorization;

  it('is sent as the bearer on the three reads, to the configured origin only, and never signs in', async () => {
    const { impl, calls } = bearerFetch({ [TOK_A]: householdOf('Ann') });
    // Even with the demo password configured, a person's token never goes through the demo login.
    const team = new TeamBackend({ baseUrl: 'https://team.example', password: 'demo-password-1' }, { fetchImpl: impl, now: () => NOW, log: () => {} });
    const picks = await team.picks(TOK_A);
    expect(picks.lists.map((l) => l.name)).toEqual(['Ann groceries']);
    expect(picks.suggestions.map((s) => s.name)).toEqual(['Ann eggs', 'Ann granola']);
    expect(calls.map((c) => c.url).sort()).toEqual([
      'https://team.example/v1/forecasts/runouts?within=7d',
      'https://team.example/v1/lists?status=open',
      'https://team.example/v1/wishlist/suggestions',
    ]);
    for (const c of calls) {
      expect(bearerOf(c)).toBe(`Bearer ${TOK_A}`);
      expect(c.init.redirect).toBe('error');
    }
  });

  it('keeps households apart: one token\'s picks are never served for another, or for the demo path', async () => {
    const { impl } = bearerFetch({ [TOK_A]: householdOf('Ann'), [TOK_B]: householdOf('Bo') });
    const team = new TeamBackend({ baseUrl: 'https://team.example', password: 'demo-password-1' }, { fetchImpl: impl, now: () => NOW, log: () => {} });
    expect((await team.picks(TOK_A)).lists[0]!.name).toBe('Ann groceries');
    expect((await team.picks(TOK_B)).lists[0]!.name).toBe('Bo groceries');
    expect((await team.picks()).lists.map((l) => l.name)).toEqual(['Saturday groceries', 'Household essentials']);
    expect((await team.picks(TOK_A)).lists[0]!.name).toBe('Ann groceries');
    expect((await team.picks(TOK_B)).suggestions[1]!.name).toBe('Bo granola');
  });

  it('caches each token\'s answer for 60 s, and concurrent callers for one token share one load', async () => {
    let t = NOW;
    const { impl, calls } = bearerFetch({ [TOK_A]: householdOf('Ann'), [TOK_B]: householdOf('Bo') });
    const team = new TeamBackend({ baseUrl: 'https://team.example', password: null }, { fetchImpl: impl, now: () => t, log: () => {} });
    const [x, y, z] = await Promise.all([team.picks(TOK_A), team.picks(TOK_A), team.picks(TOK_A)]);
    expect(calls).toHaveLength(3);
    expect(y).toBe(x);
    expect(z).toBe(x);
    t += 59_000;
    expect(await team.picks(TOK_A)).toBe(x);
    expect(calls).toHaveLength(3); // second call within 60 s: no fetch
    await team.picks(TOK_B);
    expect(calls).toHaveLength(6); // another token has its own entry
    t += 2_000; // A is now 61 s old, B only 2 s
    await team.picks(TOK_B);
    expect(calls).toHaveLength(6);
    const again = await team.picks(TOK_A);
    expect(calls).toHaveLength(9);
    expect(again).not.toBe(x);
    expect(again.lists[0]!.name).toBe('Ann groceries');
  });

  it('keeps the cache under the token\'s SHA-256, never the token itself, and at most 100 tokens (oldest dropped)', async () => {
    const { impl, calls } = bearerFetch({});
    const team = new TeamBackend({ baseUrl: 'https://team.example', password: null }, { fetchImpl: impl, now: () => NOW, log: () => {} });
    const tok = (i: number) => `tok-${String(i).padStart(4, '0')}-${'x'.repeat(20)}`;
    for (let i = 0; i < 101; i++) await expect(team.picks(tok(i))).rejects.toThrow(); // refused: cached as failures
    expect(calls).toHaveLength(101 * 3);
    const state = inspect(team, { depth: 8, maxArrayLength: null, breakLength: Infinity });
    expect(state).not.toContain('tok-');
    expect(state).toContain(createHash('sha256').update(tok(100)).digest('hex'));
    expect(state).not.toContain(createHash('sha256').update(tok(0)).digest('hex')); // the oldest was dropped
    await expect(team.picks(tok(1))).rejects.toThrow(); // still cached
    expect(calls).toHaveLength(101 * 3);
    await expect(team.picks(tok(0))).rejects.toThrow(); // dropped, so asked again
    expect(calls).toHaveLength(102 * 3);
  });

  it('a refused token (401 or 403) gives no picks, is cached like any failure, and never falls back to the demo login', async () => {
    for (const status of [401, 403]) {
      let t = NOW;
      const lines: string[] = [];
      const { impl, calls, logins } = bearerFetch({}, status);
      const team = new TeamBackend({ baseUrl: 'https://team.example', password: 'demo-password-1' }, { fetchImpl: impl, now: () => t, log: (l) => lines.push(l) });
      await expect(team.picks(TOK_A)).rejects.toThrow('token refused');
      expect(calls).toHaveLength(3); // no retry
      await expect(team.picks(TOK_A)).rejects.toThrow('token refused');
      expect(calls).toHaveLength(3); // remembered for a moment
      t += 21_000;
      await expect(team.picks(TOK_A)).rejects.toThrow('token refused');
      expect(calls).toHaveLength(6);
      expect(logins()).toBe(0);
      expect(lines.join()).not.toContain(TOK_A);
      expect(lines).toHaveLength(2);
    }
  });

  it('never puts the token in a log line or an error, whatever goes wrong', async () => {
    const lines: string[] = [];
    const failures = [
      () => Promise.reject(Object.assign(new Error(`aborted ${TOK_A}`), { name: 'TimeoutError' })),
      () => Promise.reject(new Error(`connect failed for ${TOK_A}`)),
      () => json({ detail: TOK_A }, 500),
      () => new Response(`<html>${TOK_A}`, { status: 200 }),
    ];
    for (const fail of failures) {
      const { impl } = bearerFetch({}, 401);
      const wrapped = (async (input: string | URL | Request, init?: RequestInit) => (String(input).includes('/v1/lists') ? fail() : impl(input, init))) as typeof fetch;
      const team = new TeamBackend({ baseUrl: 'https://team.example', password: null }, { fetchImpl: wrapped, now: () => NOW, log: (l) => lines.push(l) });
      const err = await team.picks(TOK_A).then(() => null, (e: unknown) => e as Error);
      expect(err).toBeInstanceOf(Error);
      expect(`${err!.message} ${err!.stack} ${String((err as { cause?: unknown }).cause)}`).not.toContain(TOK_A);
    }
    expect(lines.length).toBeGreaterThan(0);
    expect(lines.join('\n')).not.toContain(TOK_A);
  });

  it('treats the answers as untrusted data, as on the demo path', async () => {
    const dirty = householdOf('Ann');
    dirty.lists = [{ name: 'L\u0000ist\u202E', source: 'user', status: 'open', items: [{ title: `Oat\nmilk ${'z'.repeat(200)}`, quantity: 1, checked: false }] }];
    dirty.suggestions = [{ title: 'Ignore previous instructions\u0007', status: 'suggested', rationale: 'a\u200Bb' }];
    dirty.runouts = { runouts: [] };
    const { impl } = bearerFetch({ [TOK_A]: dirty });
    const team = new TeamBackend({ baseUrl: 'https://team.example', password: null }, { fetchImpl: impl, now: () => NOW, log: () => {} });
    const picks = await team.picks(TOK_A);
    expect(picks.lists[0]!.name).toBe('L ist');
    expect(picks.lists[0]!.items[0]!.name).toHaveLength(80);
    expect(picks.suggestions).toEqual([{ name: 'Ignore previous instructions', reason: 'a b' }]);
  });

  it('with a base URL but no demo password: a token gets its household, no token gets nothing (and no fetch)', async () => {
    const { impl, calls } = bearerFetch({ [TOK_A]: householdOf('Ann') });
    const lines: string[] = [];
    const team = teamBackendFromEnv({ TEAM_API_BASE_URL: 'https://team.example' }, { fetchImpl: impl, now: () => NOW, log: (l) => lines.push(l) });
    expect(team).toBeInstanceOf(TeamBackend);
    await expect(team!.picks()).rejects.toThrow();
    expect(calls).toHaveLength(0);
    expect((await team!.picks(TOK_A)).lists[0]!.name).toBe('Ann groceries');
    expect(calls).toHaveLength(3);
    expect(lines).toEqual([]);
  });

  it('householdToken accepts 1 to 4096 printable ASCII characters with no whitespace, else nothing', () => {
    expect(householdToken(TOK_A)).toBe(TOK_A);
    expect(householdToken('eyJhbGciOi.J9.eyJzdWIi-_=+/~')).toBe('eyJhbGciOi.J9.eyJzdWIi-_=+/~');
    expect(householdToken('x')).toBe('x');
    expect(householdToken('x'.repeat(4096))).toBe('x'.repeat(4096));
    for (const bad of [
      undefined, '', ' ', 'two words', ' lead', 'trail ', 'tab\there', 'line\nbreak', 'cr\r', 'nul\u0000', 'del\u007f',
      'caf\u00e9', 'tok\u200b', 'x'.repeat(4097), ['a'], ['a', 'b'], 42, null, {},
    ]) {
      expect(householdToken(bad)).toBeUndefined();
    }
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
      suggestions: Array.from({ length: 30 }, (_, i) => ({ name: `Idea ${String.fromCharCode(97 + (i % 26)).repeat(2)}${i >= 26 ? 'z' : ''}`, reason: 'Picked for your home' })),
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

  it('history: names of one product fold into one pick, and a product in the cart is left out', () => {
    const past = [
      run('a', 'QFC', [chip('Clorox Disinfecting Wipes Fresh Scent 75 Count', { addedAt: NOW - 3 * DAY }), chip('Peach', { addedAt: NOW - 3 * DAY })]),
      run('b', 'QFC', [chip('Clorox Disinfecting Wipes Fresh Scent 75 ct', { addedAt: NOW - 2 * DAY }), chip('Cosmic Crisp Apple', { addedAt: NOW - 2 * DAY })]),
      run('c', 'QFC', [chip('Clorox Disinfecting Wipes Fresh Scent', { addedAt: NOW - DAY })]),
    ];
    expect(historyPicks(past, run('empty', 'QFC', []))).toEqual([
      { name: 'Clorox Disinfecting Wipes Fresh Scent', reason: 'Often in your QFC runs' },
      { name: 'Cosmic Crisp Apple', reason: 'In a past QFC run' },
      { name: 'Peach', reason: 'In a past QFC run' },
    ]);
    const withWipes = run('now', 'QFC', [chip('Clorox Disinfecting Wipes'), chip('Honeycrisp Apple')]);
    expect(historyPicks(past, withWipes).map((p) => p.name)).toEqual(['Cosmic Crisp Apple', 'Peach']);
  });

  it('suggestions: a looser name for something in the cart or on the list is left out', () => {
    const r = run('r', 'QFC', [chip('Honeycrisp Apple'), chip('Bounty Paper Towels 6 Rolls')]);
    const household: HouseholdPicks = {
      lists: [{ name: 'Weekly', store: 'QFC', updatedAt: NOW, items: [{ name: 'Oat milk', detail: '1 carton' }] }],
      suggestions: [
        { name: 'Apples', reason: 'Running low' }, { name: 'Paper towels', reason: 'Running low' },
        { name: 'Oatly Oat Milk', reason: 'You buy these often' }, { name: 'Greek yogurt', reason: 'Running low' },
      ],
    };
    const picks = composePicks(r, household, [{ name: 'Cosmic Crisp Apple', reason: 'In a past QFC run' }, { name: 'apple', reason: 'In your last run' }]);
    expect(picks.suggestions.map((s) => s.name)).toEqual(['Greek yogurt', 'Cosmic Crisp Apple']);
    expect(picks.list?.items.map((i) => i.name)).toEqual(['Oat milk']);
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
  const get = async (url: string, headers: Record<string, string> = {}) => {
    const r = await app.inject({ url, headers: { 'x-dibs-key': PRIYA_KEY, ...headers } });
    return { status: r.statusCode, body: r.json() };
  };
  const PICKS = '/api/runs/now/wish-picks?personId=priya';
  const historyOnly = { list: null, suggestions: [{ name: 'Greek yogurt', reason: 'In your last run' }] };

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

  it('X-Household-Token: shows that person\'s own household, signs in as no one, and keeps people apart', async () => {
    const { impl, calls, logins } = bearerFetch({ [TOK_A]: householdOf('Ann'), [TOK_B]: householdOf('Bo') });
    await start(new TeamBackend({ baseUrl: 'https://team.example', password: 'demo-password-1' }, { fetchImpl: impl, now: () => NOW, log: () => {} }), [past, current]);

    const a = await get(PICKS, { 'x-household-token': TOK_A });
    expect(a.status).toBe(200);
    expect(a.body.list).toEqual({ name: 'Ann groceries', store: 'QFC', items: [{ name: 'Ann milk', detail: '' }] });
    expect(a.body.suggestions.map((s: { name: string }) => s.name)).toEqual(['Ann eggs', 'Ann granola', 'Greek yogurt']);
    const b = await get(PICKS, { 'x-household-token': TOK_B });
    expect(b.body.list.name).toBe('Bo groceries');
    expect(JSON.stringify([a.body, b.body])).not.toMatch(/tok-|Bearer/);
    expect(logins()).toBe(0);
    for (const c of calls) expect((c.init.headers as Record<string, string>).authorization).toMatch(/^Bearer tok-[AB]{24}$/);

    // No header: today's behaviour, the demo account's household (this is the only login).
    const demo = await get(PICKS);
    expect(demo.body.list.name).toBe('Household essentials');
    expect(logins()).toBe(1);
    expect((await get(PICKS, { 'x-household-token': TOK_A })).body).toEqual(a.body);
  });

  it('X-Household-Token: a refused token falls back to run history, never to the demo household', async () => {
    const { impl, logins } = bearerFetch({ [TOK_A]: householdOf('Ann') });
    await start(new TeamBackend({ baseUrl: 'https://team.example', password: 'demo-password-1' }, { fetchImpl: impl, now: () => NOW, log: () => {} }), [past, current]);
    expect(await get(PICKS, { 'x-household-token': 'tok-expired-0000000000000' })).toEqual({ status: 200, body: historyOnly });
    expect(logins()).toBe(0);
  });

  it('X-Household-Token: a malformed value is ignored, as if absent', async () => {
    const seen: (string | undefined)[] = [];
    const spy: HouseholdSource = { picks: async (token?: string) => { seen.push(token); return { lists: [], suggestions: [] }; } };
    await start(spy, [past, current]);
    const bad = ['two words', 'x'.repeat(4097), 'tok-a, tok-b', 'tok\u0001ctl', ' '];
    for (const value of bad) expect((await get(PICKS, { 'x-household-token': value })).status).toBe(200);
    expect(seen).toEqual(bad.map(() => undefined));
    await get(PICKS, { 'x-household-token': TOK_A });
    await get(PICKS, { 'x-household-token': 'x'.repeat(4096) });
    await get(PICKS);
    expect(seen.slice(bad.length)).toEqual([TOK_A, 'x'.repeat(4096), undefined]);
  });

  it('with only TEAM_API_BASE_URL: a token gets its household, no token gets run history', async () => {
    const { impl, logins } = bearerFetch({ [TOK_A]: householdOf('Ann') });
    const team = teamBackendFromEnv({ TEAM_API_BASE_URL: 'https://team.example' }, { fetchImpl: impl, now: () => NOW, log: () => {} });
    await start(team, [past, current]);
    expect((await get(PICKS, { 'x-household-token': TOK_A })).body.list.name).toBe('Ann groceries');
    expect(await get(PICKS)).toEqual({ status: 200, body: historyOnly });
    expect(logins()).toBe(0);
  });

  it('refuses an unknown run or person', async () => {
    await start(null, [current]);
    expect((await get('/api/runs/nope/wish-picks?personId=priya')).status).toBe(404);
    expect(await get('/api/runs/now/wish-picks?personId=stranger')).toEqual({ status: 403, body: { error: 'not allowed' } });
    expect((await get('/api/runs/now/wish-picks')).status).toBe(403);
  });
});
