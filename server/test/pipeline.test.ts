import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { identifyPipeline, type PipelineDeps } from '../src/pipeline.js';
import { StubPrice } from '../src/price/stub.js';
import { seedRun } from '../src/seed.js';
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

  it('leaves a failed identify identifying, then a retry opens it', async () => {
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
    const [stuck] = store.get(run.id)!.chips;
    expect(stuck.state).toBe('identifying');
    expect(errors).toEqual([{ t: 'error', reason: 'identify failed' }]);
    fail = false;
    await identifyPipeline(deps, run.id, ev.frameBase64, ev.region, stuck.id);
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
    expect(seen).toEqual([{ runId: run.id }]);
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
});
