// Fastify REST API plus the run WebSocket (`ws` attached to Fastify's HTTP server at /ws).
import { existsSync } from 'node:fs';
import { dirname, join as pathJoin } from 'node:path';
import { fileURLToPath } from 'node:url';
import cors from '@fastify/cors';
import fastifyStatic from '@fastify/static';
import Fastify, { type FastifyInstance, type FastifyReply } from 'fastify';
import QRCode from 'qrcode';
import { WebSocketServer } from 'ws';
import { getPayments, type PaymentsProvider, type TestCard } from './payments/provider.js';
import { getPrice, type PriceProvider } from './price/provider.js';
import { parseClientMsg } from './protocol.js';
import {
  addChip, backToCart, checkout, claim, fixChip, join as joinRun, leave, lock, putBack, removeChip,
  setAuthorization, setChipLive, setChipPrice, undoRemove, wish,
} from './run.js';
import { seedRun } from './seed.js';
import { applyReceipt, fixReceiptLine, matchReceipt, parseReceiptLines, settle } from './settle.js';
import { createStore } from './store.js';
import type { Run } from './types.js';
import { getVision, type VisionProvider } from './vision/provider.js';

export type Deps = {
  payments: PaymentsProvider;
  vision: VisionProvider;
  price: PriceProvider;
  now?: () => number;
  lastCallMs?: number;
  dataDir?: string;
};

const here = dirname(fileURLToPath(import.meta.url));

export async function buildServer(deps: Deps): Promise<FastifyInstance> {
  const { payments, vision, price } = deps;
  const now = deps.now ?? Date.now;
  const lastCallMs = deps.lastCallMs ?? 10000;
  const store = createStore(deps.dataDir ?? pathJoin(here, '..', '.data'));
  const app = Fastify();
  await app.register(cors, { origin: true });

  const timers = new Map<string, NodeJS.Timeout>();
  const settling = new Map<string, Promise<unknown>>();
  let raiseCounter = 0;

  const fail = (reply: FastifyReply, error: string) =>
    reply.code(error === 'unknown run' ? 404 : 409).send({ error });
  const ref = (runId: string) => (personId: string, step: string) => `${runId}-${personId}-${step}`;

  /** Looks up the run and, for shopper-only routes, checks the caller. Sends the error reply itself. */
  function guard(reply: FastifyReply, runId: string, personId?: string, shopperOnly = false): Run | null {
    const run = store.get(runId);
    if (!run) {
      void reply.code(404).send({ error: 'unknown run' });
      return null;
    }
    if (shopperOnly && personId !== run.shopperId) {
      void reply.code(403).send({ error: 'shopper only' });
      return null;
    }
    return run;
  }

  // ---- runs ----
  app.post('/api/runs', async () => {
    const run = seedRun(now());
    store.add(run);
    return { runId: run.id, shopperId: run.shopperId };
  });

  app.get<{ Params: { id: string } }>('/api/runs/:id', async (req, reply) => {
    const run = store.get(req.params.id);
    return run ?? reply.code(404).send({ error: 'unknown run' });
  });

  app.get<{ Params: { id: string } }>('/api/runs/:id/qr', async (req, reply) => {
    if (!store.get(req.params.id)) return reply.code(404).send({ error: 'unknown run' });
    const url = `${process.env.PUBLIC_URL ?? 'http://localhost:3000'}/join?run=${req.params.id}`;
    const png = await QRCode.toBuffer(url, { type: 'png' });
    return reply.type('image/png').send(png);
  });

  app.post<{ Params: { id: string }; Body: { name: string; card: TestCard; capCents: number } }>(
    '/api/runs/:id/join',
    async (req, reply) => {
      const run = guard(reply, req.params.id);
      if (!run) return;
      const { name, card, capCents } = req.body;
      if (run.state !== 'open' && run.state !== 'lastCall') return fail(reply, 'cart closed');
      const personId = crypto.randomUUID();
      let auth;
      try {
        auth = await payments.authorize(ref(run.id)(personId, 'authorize'), card, capCents);
      } catch {
        return reply.code(502).send({ error: 'payments unavailable' });
      }
      if (auth.status !== 'AUTHORIZED') return reply.code(409).send({ error: 'declined' });
      const res = store.update(run.id, (r) => {
        const joined = joinRun(r, {
          id: personId, name, initial: (name.trim()[0] ?? '?').toUpperCase(), isShopper: false,
          authorizedCents: null, authId: null, payoutPan: null,
        });
        return 'error' in joined ? joined : setAuthorization(joined, personId, auth.authorizedCents, auth.authId);
      });
      if ('error' in res) return fail(reply, res.error);
      return { personId, auth };
    },
  );

  app.post<{ Params: { id: string }; Body: { personId: string; capCents: number } }>(
    '/api/runs/:id/raise',
    async (req, reply) => {
      if (process.env.RAISE_CAP === 'off') return reply.code(403).send({ error: 'raise off' });
      const run = guard(reply, req.params.id);
      if (!run) return;
      if (run.state !== 'open' && run.state !== 'lastCall') return fail(reply, 'cart closed');
      const { personId, capCents } = req.body;
      const p = run.people.find((x) => x.id === personId);
      if (!p || p.isShopper || p.authId === null || p.authorizedCents === null) return fail(reply, 'unknown person');
      const authId = p.authId;
      const current = p.authorizedCents;
      if (capCents <= current) return { status: 'AUTHORIZED', authId, approvalCode: '', authorizedCents: current };
      raiseCounter += 1;
      let auth;
      try {
        auth = await payments.incremental(ref(run.id)(personId, `raise${raiseCounter}`), authId, capCents - current);
      } catch {
        return reply.code(502).send({ error: 'payments unavailable' });
      }
      if (auth.status !== 'AUTHORIZED') return reply.code(409).send({ error: 'declined' });
      const res = store.update(run.id, (r) => setAuthorization(r, personId, auth.authorizedCents, authId));
      if ('error' in res) return fail(reply, res.error);
      return auth;
    },
  );

  // ---- chips ----
  app.post<{ Params: { id: string }; Body: { imageBase64: string; hint?: string } }>(
    '/api/runs/:id/chips',
    async (req, reply) => {
      const run = guard(reply, req.params.id);
      if (!run) return;
      const id = crypto.randomUUID();
      const added = store.update(run.id, (r) =>
        addChip(r, { id, name: '', priceCents: null, priceSource: 'none', photoUrl: null, region: null, quantity: 1 }, now()),
      );
      if ('error' in added) return fail(reply, added.error);
      if (!added.run.chips.some((c) => c.id === id)) return fail(reply, 'cart closed');
      let found;
      try {
        found = await vision.identify(req.body.imageBase64 ?? '', req.body.hint);
      } catch {
        store.update(run.id, (r) => ({ ...r, chips: r.chips.filter((c) => c.id !== id) }));
        return reply.code(502).send({ error: 'identify failed' });
      }
      const source = found.priceCents === null ? 'none' : 'sticker';
      const live = store.update(run.id, (r) => {
        const next = setChipLive(r, id, found.name, found.priceCents, source, now());
        return next.chips.find((c) => c.id === id)?.photoUrl === null
          ? { ...next, chips: next.chips.map((c) => (c.id === id ? { ...c, photoUrl: `data:image/jpeg;base64,${found.cropBase64}` } : c)) }
          : next;
      });
      if ('error' in live) return fail(reply, live.error);
      if (found.priceCents === null) {
        void price
          .lookup(found.name, run.store)
          .then((hit) => {
            if (!hit) return;
            // Discard a late price unless the chip is still unpriced and the run still takes changes.
            store.update(run.id, (r) => {
              const c = r.chips.find((x) => x.id === id);
              const open = r.state === 'open' || r.state === 'lastCall';
              if (!c || !open || c.priceSource !== 'none' || c.state === 'removed' || c.dropped) return r;
              return setChipPrice(r, id, hit.cents, 'web');
            });
          })
          .catch(() => undefined);
      }
      return live.run.chips.find((c) => c.id === id) ?? fail(reply, 'cart closed');
    },
  );

  app.post<{ Params: { id: string }; Body: { name: string; byPersonId: string } }>(
    '/api/runs/:id/chips/text',
    async (req, reply) => {
      const run = guard(reply, req.params.id);
      if (!run) return;
      const { name, byPersonId } = req.body;
      if (!run.people.some((p) => p.id === byPersonId)) return fail(reply, 'unknown person');
      const res = store.update(run.id, (r) => wish(r, byPersonId, name, now()));
      if ('error' in res) return fail(reply, res.error);
      return res.run;
    },
  );

  app.post<{ Params: { id: string; chipId: string }; Body: { personId: string; name?: string; priceCents?: number } }>(
    '/api/runs/:id/chips/:chipId/fix',
    async (req, reply) => {
      if (!guard(reply, req.params.id, req.body.personId, true)) return;
      const { name, priceCents } = req.body;
      const res = store.update(req.params.id, (r) => fixChip(r, req.params.chipId, name, priceCents, now()));
      return 'error' in res ? fail(reply, res.error) : res.run;
    },
  );

  app.post<{ Params: { id: string; chipId: string }; Body: { personId: string } }>(
    '/api/runs/:id/chips/:chipId/putback',
    async (req, reply) => {
      if (!guard(reply, req.params.id, req.body.personId, true)) return;
      const res = store.update(req.params.id, (r) => putBack(r, req.params.chipId));
      return 'error' in res ? fail(reply, res.error) : res.run;
    },
  );

  // ---- checkout / lock ----
  app.post<{ Params: { id: string }; Body: { personId: string } }>('/api/runs/:id/checkout', async (req, reply) => {
    const run = guard(reply, req.params.id, req.body.personId, true);
    if (!run) return;
    const wasOpen = run.state === 'open';
    const res = store.update(run.id, (r) => checkout(r, now(), lastCallMs));
    if ('error' in res) return fail(reply, res.error);
    const endsAt = res.run.lastCallEndsAt;
    if (wasOpen && endsAt !== null) {
      store.broadcast(run.id, { t: 'lastCall', endsAt });
      timers.set(
        run.id,
        setTimeout(() => {
          timers.delete(run.id);
          try {
            const locked = store.update(run.id, (r) => lock(r, Math.max(now(), endsAt)));
            if (!('error' in locked) && locked.run.state === 'locked') store.broadcast(run.id, { t: 'locked' });
          } catch (e) {
            console.error('lock failed', e);
          }
        }, Math.max(0, endsAt - now())),
      );
    }
    return res.run;
  });

  app.post<{ Params: { id: string }; Body: { personId: string } }>('/api/runs/:id/back', async (req, reply) => {
    if (!guard(reply, req.params.id, req.body.personId, true)) return;
    clearTimeout(timers.get(req.params.id));
    timers.delete(req.params.id);
    const res = store.update(req.params.id, (r) => backToCart(r));
    return 'error' in res ? fail(reply, res.error) : res.run;
  });

  // ---- receipt and settle ----
  app.post<{ Params: { id: string }; Body: { imageBase64: string } }>('/api/runs/:id/receipt', async (req, reply) => {
    const run = guard(reply, req.params.id);
    if (!run) return;
    if (run.state !== 'locked' && run.state !== 'receipt') return fail(reply, 'not locked');
    if (settling.has(run.id)) return fail(reply, 'settling');
    let lines;
    try {
      lines = parseReceiptLines(await vision.readReceipt(req.body.imageBase64 ?? ''));
    } catch {
      return reply.code(502).send({ error: 'receipt read failed' });
    }
    if (settling.has(run.id)) return fail(reply, 'settling');
    const res = store.update(run.id, (r) =>
      r.state === 'locked' || r.state === 'receipt' ? applyReceipt(r, matchReceipt(r, lines)) : { error: 'not locked' },
    );
    return 'error' in res ? fail(reply, res.error) : res.run.receipt;
  });

  app.post<{ Params: { id: string }; Body: { lineIndex: number; target: { chipId: string } | 'mine' } }>(
    '/api/runs/:id/receipt/fix',
    async (req, reply) => {
      const run = guard(reply, req.params.id);
      if (!run) return;
      if (run.state !== 'receipt' || settling.has(run.id)) return fail(reply, 'no receipt');
      const res = store.update(run.id, (r) => fixReceiptLine(r, req.body.lineIndex, req.body.target));
      return 'error' in res ? fail(reply, res.error) : res.run.receipt;
    },
  );

  app.post<{ Params: { id: string }; Body: { personId: string } }>('/api/runs/:id/confirm', async (req, reply) => {
    const run = guard(reply, req.params.id, req.body.personId, true);
    if (!run) return;
    if (run.state !== 'receipt' && run.state !== 'partlySettled' && run.state !== 'settled') return fail(reply, 'no receipt');
    // Serialize per run: a second confirm waits for the first, then re-runs against the stored progress.
    const prev = settling.get(run.id) ?? Promise.resolve();
    const mine = prev.catch(() => undefined).then(() =>
      settle(store.get(run.id) as Run, payments, ref(run.id), (r) => store.save(r)),
    );
    settling.set(run.id, mine);
    try {
      return await mine;
    } catch {
      return reply.code(500).send({ error: 'settle failed' });
    } finally {
      if (settling.get(run.id) === mine) settling.delete(run.id);
    }
  });

  // ---- WebSocket ----
  const wss = new WebSocketServer({ noServer: true });
  app.server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    if (url.pathname !== '/ws') {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      const runId = url.searchParams.get('run') ?? '';
      const personId = url.searchParams.get('person') ?? '';
      const run = store.get(runId);
      if (!run || !run.people.some((p) => p.id === personId)) {
        ws.close(1008, 'unknown run or person');
        return;
      }
      store.attach(runId, ws);
      store.send(ws, { t: 'run', run });
      ws.on('message', (data) => {
        const msg = parseClientMsg(String(data));
        if (!msg) return store.send(ws, { t: 'error', reason: 'bad message' });
        const cur = store.get(runId);
        const shopper = cur?.shopperId === personId;
        if ((msg.t === 'remove' || msg.t === 'undoRemove') && !shopper) {
          return store.send(ws, { t: 'error', reason: 'shopper only' });
        }
        try {
          const res = store.update(runId, (r) => {
            switch (msg.t) {
              case 'claim': return claim(r, msg.chipId, personId, now());
              case 'leave': return leave(r, msg.chipId, personId);
              case 'remove': return removeChip(r, msg.chipId, now());
              case 'undoRemove': return undoRemove(r, msg.chipId, now());
            }
          });
          if ('error' in res) store.send(ws, { t: 'error', reason: res.error });
        } catch (e) {
          console.error('ws message failed', e);
          store.send(ws, { t: 'error', reason: 'server error' });
        }
      });
    });
  });

  const webOut = pathJoin(here, '..', '..', 'web', 'out');
  if (existsSync(webOut)) await app.register(fastifyStatic, { root: webOut });

  app.addHook('onClose', async () => {
    for (const t of timers.values()) clearTimeout(t);
    timers.clear();
    for (const c of wss.clients) c.terminate();
    wss.close();
  });

  return app;
}

async function main(): Promise<void> {
  const app = await buildServer({
    payments: getPayments(),
    vision: getVision(),
    price: getPrice(),
    lastCallMs: Number(process.env.LAST_CALL_MS ?? 10000),
  });
  await app.listen({ port: Number(process.env.PORT ?? 3000), host: '0.0.0.0' });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
