import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { identifyPipeline, resumePriceLookups, type PipelineDeps } from '../src/pipeline.js';
import { StubPrice } from '../src/price/stub.js';
import { seedRun } from '../src/seed.js';
import { claim, join as joinRun, wish } from '../src/run.js';
import { createStore } from '../src/store.js';
import { StubVision } from '../src/vision/stub.js';
import { DiffDetector } from '../src/vision/detect-diff.js';
import type { Identified, VisionProvider } from '../src/vision/provider.js';
import type { Box } from '../src/types.js';

const frame = (n: string) => readFileSync(join(import.meta.dirname, 'fixtures', 'frames', `${n}.jpg`)).toString('base64');
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function eggs(): Promise<{ frameBase64: string; region: Box }> {
  const d = new DiffDetector({ settleMs: 1000, minChangedFraction: 0.04 });
  const seq = [...Array(6).fill('empty'), 'eggs-moving1', 'eggs-moving2', 'eggs-still', 'eggs-still', 'eggs-still'];
  for (let i = 0; i < seq.length; i++) {
    for (const ev of await d.push({ jpegBase64: frame(seq[i]), at: i * 500 })) if (ev.kind === 'newItem') return ev;
  }
  throw new Error('no newItem');
}

function setup(vision: VisionProvider = new StubVision()) {
  const store = createStore(mkdtempSync(join(tmpdir(), 'dibs-')));
  const run = seedRun(1000);
  store.add(run);
  const errors: unknown[] = [];
  const deps: PipelineDeps = { store, vision, price: new StubPrice(), now: () => 1000, toShopper: (_r, m) => errors.push(m) };
  return { store, run, deps, errors };
}

describe('identifyPipeline', () => {
  it('makes a live sticker-priced chip from a newItem', async () => {
    const { store, run, deps } = setup();
    const ev = await eggs();
    await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
    const [chip] = store.get(run.id)!.chips;
    expect(chip.name).toMatch(/Eggs/);
    expect(chip.priceCents).toBe(872);
    expect(chip.priceSource).toBe('sticker');
    expect(chip.state).toBe('open');
    expect(chip.region).toEqual(ev.region);
    expect(chip.photoUrl).toMatch(/^data:image\/jpeg;base64,/);
  });

  it('goes live unpriced, then takes the web price', async () => {
    const stub = new StubVision();
    const noSticker: VisionProvider = {
      identify: async (...a): Promise<Identified> => ({ ...(await stub.identify(...a)), priceCents: null }),
      readReceipt: (i) => stub.readReceipt(i),
    };
    const { store, run, deps } = setup(noSticker);
    const ev = await eggs();
    await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
    for (let i = 0; i < 100 && store.get(run.id)!.chips[0].priceSource === 'none'; i++) await sleep(10);
    const chip = store.get(run.id)!.chips[0];
    expect(chip.priceCents).toBe(872);
    expect(chip.priceSource).toBe('web');
  });

  it('drops a failed identify at once; the next detection adds it fresh', async () => {
    const stub = new StubVision();
    let fail = true;
    const flaky: VisionProvider = {
      identify: async (...a) => {
        if (fail) throw new Error('down');
        return stub.identify(...a);
      },
      readReceipt: (i) => stub.readReceipt(i),
    };
    const { store, run, deps, errors } = setup(flaky);
    const ev = await eggs();
    await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
    expect(store.get(run.id)!.chips).toEqual([]);
    expect(errors).toEqual([{ t: 'error', reason: 'identify failed' }]);
    fail = false;
    await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
    const chips = store.get(run.id)!.chips;
    expect(chips).toHaveLength(1);
    expect(chips[0].state).toBe('open');
    expect(chips[0].priceCents).toBe(872);
  });

  it('passes the run id to vision as context', async () => {
    const stub = new StubVision();
    const seen: unknown[] = [];
    const spy: VisionProvider = {
      identify: async (...a) => {
        seen.push(a[3]);
        return stub.identify(...a);
      },
      readReceipt: (i) => stub.readReceipt(i),
    };
    const { run, deps } = setup(spy);
    const ev = await eggs();
    await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
    expect(seen).toEqual([{ runId: run.id, cartNames: [], wishNames: [] }]);
  });

  it('marks a second identical identification within 5 s as a duplicate', async () => {
    const { store, run, deps } = setup();
    let t = 1000;
    deps.now = () => t;
    const ev = await eggs();
    await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
    t = 4000;
    await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
    t = 12000;
    await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
    const [a, b, c] = store.get(run.id)!.chips;
    expect(a.duplicateOf).toBeNull();
    expect(b.name).toBe(a.name);
    expect(b.duplicateOf).toBe(a.id);
    expect(c.duplicateOf).toBeNull();
  });

  it('with MERGE_DUPLICATES=1 folds a re-detection into the existing chip', async () => {
    process.env.MERGE_DUPLICATES = '1';
    try {
      const { store, run, deps } = setup();
      let t = 1000;
      deps.now = () => t;
      const ev = await eggs();
      await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
      const firstId = store.get(run.id)!.chips[0].id;
      t = 4000;
      await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
      const chips = store.get(run.id)!.chips;
      expect(chips.map((c) => c.id)).toEqual([firstId]);
      expect(chips[0].duplicateOf).toBeNull();
    } finally {
      delete process.env.MERGE_DUPLICATES;
    }
  });

  describe('with MERGE_DUPLICATES=1', () => {
    afterEach(() => {
      delete process.env.MERGE_DUPLICATES;
      delete process.env.MERGE_WINDOW_MS;
    });

    it('counts the same product seen again as one more on the same chip, never a second chip or a duplicate card', async () => {
      process.env.MERGE_DUPLICATES = '1';
      const { store, run, deps } = setup();
      let t = 1000;
      deps.now = () => t;
      const ev = await eggs();
      const seen = async (at: number) => {
        t = at;
        await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
        return store.get(run.id)!.chips;
      };
      const [first] = await seen(1000);
      // Within 3 s of the last count it is the same detection (a merged box, a double tap): no change.
      expect((await seen(2500)).map((c) => [c.id, c.quantity])).toEqual([[first.id, 1]]);
      expect((await seen(10_000)).map((c) => [c.id, c.quantity])).toEqual([[first.id, 2]]);
      expect((await seen(11_000)).map((c) => [c.id, c.quantity])).toEqual([[first.id, 2]]);
      const chips = await seen(60_000);
      expect(chips.map((c) => [c.id, c.quantity])).toEqual([[first.id, 3]]);
      expect(chips[0].duplicateOf).toBeNull();
      expect(chips[0].priceCents).toBe(872); // still the unit price
    });

    it('MERGE_WINDOW_MS sets the same-detection window', async () => {
      process.env.MERGE_DUPLICATES = '1';
      process.env.MERGE_WINDOW_MS = '20000';
      const { store, run, deps } = setup();
      let t = 1000;
      deps.now = () => t;
      const ev = await eggs();
      await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
      t = 15_000;
      await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
      expect(store.get(run.id)!.chips.map((c) => c.quantity)).toEqual([1]);
    });

    it('a waiting wish for the product takes the new item instead of counting it again', async () => {
      process.env.MERGE_DUPLICATES = '1';
      const { store, run, deps } = setup();
      let t = 1000;
      deps.now = () => t;
      const ev = await eggs();
      await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
      const first = store.get(run.id)!.chips[0];
      const priya = { id: 'p', name: 'Priya', initial: 'P', isShopper: false, authorizedCents: 4000, authId: 'auth-p', approvalCode: '888888', payoutPan: null };
      store.update(run.id, (r) => {
        const joined = joinRun(r, priya);
        return 'error' in joined ? joined : wish(joined, 'p', first.name, 2000, 'w1');
      });
      t = 10_000;
      await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
      const chips = store.get(run.id)!.chips;
      expect(chips.find((c) => c.id === 'w1')).toBeUndefined();
      expect(chips).toHaveLength(2);
      expect(chips.find((c) => c.id === first.id)!.quantity).toBe(1);
      expect(chips.find((c) => c.id !== first.id)).toMatchObject({ claimers: ['p'], quantity: 1, duplicateOf: null });
    });

    it('re-checks the claimers of a counted chip against their caps', async () => {
      process.env.MERGE_DUPLICATES = '1';
      const { store, run, deps } = setup();
      let t = 1000;
      deps.now = () => t;
      const ev = await eggs();
      await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
      const first = store.get(run.id)!.chips[0];
      const lee = { id: 'l', name: 'Lee', initial: 'L', isShopper: false, authorizedCents: 1000, authId: 'auth-l', approvalCode: '888888', payoutPan: null };
      store.update(run.id, (r) => {
        const joined = joinRun(r, lee);
        return 'error' in joined ? joined : claim(joined, first.id, 'l', 2000);
      });
      t = 10_000;
      await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
      expect(store.get(run.id)!.chips[0]).toMatchObject({ quantity: 2, claimers: ['l'], overCap: ['l'] });
    });
  });

  it('drops the chip when vision finds no clear item, instead of leaving it identifying', async () => {
    const spy: VisionProvider = {
      identify: async () => { throw new Error('identify: no clear item'); },
      readReceipt: async () => [],
    };
    const { store, run, deps } = setup(spy);
    const ev = await eggs();
    await identifyPipeline(deps, run.id, ev.frameBase64, ev.region);
    expect(store.get(run.id)!.chips).toEqual([]);
  });

  it('asks again for prices of named, unpriced chips after a restart', async () => {
    const { store, run, deps } = setup();
    store.update(run.id, (r) => ({ ...r, chips: [{ id: 'k', name: 'Kirkland Eggs 24 ct', priceCents: null, priceSource: 'none', photoUrl: null, region: null, quantity: 1, claimers: [], state: 'open', wishedBy: null, duplicateOf: null, putBack: false, dropped: false, overCap: [], removedAt: null, addedAt: 0 }] }));
    expect(resumePriceLookups(deps)).toBe(1);
    for (let i = 0; i < 50 && store.get(run.id)!.chips[0].priceCents === null; i++) await sleep(10);
    expect(store.get(run.id)!.chips[0].priceCents).toBe(872);
  });
});

