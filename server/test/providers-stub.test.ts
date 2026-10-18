import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { describe, expect, it } from 'vitest';
import { seedRun } from '../src/seed.js';
import { StubPrice } from '../src/price/stub.js';
import { getPrice } from '../src/price/provider.js';
import { DiffDetector } from '../src/vision/detect-diff.js';
import { getDetector } from '../src/vision/detect.js';
import { getVision } from '../src/vision/provider.js';
import { StubVision } from '../src/vision/stub.js';
import type { DetectEvent } from '../src/vision/detect.js';

const here = dirname(fileURLToPath(import.meta.url));
const frame = (n: string): string => readFileSync(join(here, 'fixtures', 'frames', `${n}.jpg`)).toString('base64');
const prop = (n: string): string => readFileSync(join(here, '..', 'assets', 'props', `${n}.jpg`)).toString('base64');

describe('StubVision', () => {
  const v = new StubVision();
  it('uses the hint', async () => {
    const r = await v.identify('', 'eggs');
    expect(r.name).toContain('Eggs');
    expect(r.priceCents).toBe(872);
  });
  it('identifies props by thumbnail', async () => {
    expect((await v.identify(prop('eggs'))).name).toContain('Eggs');
    expect((await v.identify(prop('towels'))).name).toContain('Towel');
    expect((await v.identify(prop('milk'))).name).toContain('Milk');
  });
  it('identifies the eggs crop of a fixture frame', async () => {
    const r = await v.identify(frame('eggs-still'), undefined, { x: 220, y: 180, w: 200, h: 200 });
    expect(r.name).toContain('Eggs');
    expect(r.cropBase64.length).toBeGreaterThan(0);
  });
  it('cycles drop order per run when identification is inconclusive', async () => {
    const sv = new StubVision();
    const gray = (await sharp({ create: { width: 64, height: 64, channels: 3, background: { r: 215, g: 215, b: 215 } } }).jpeg().toBuffer()).toString('base64');
    const names: string[] = [];
    for (let i = 0; i < 4; i++) names.push((await sv.identify(gray, undefined, undefined, { runId: 'a' })).name);
    expect(names).toEqual(['Kirkland Eggs 24 ct', 'Paper Towels 12 pk', '2% Milk', 'Kirkland Eggs 24 ct']);
    expect((await sv.identify(gray, undefined, undefined, { runId: 'b' })).name).toBe('Kirkland Eggs 24 ct');
    // A conclusive towels identification moves the run on; the next inconclusive one is milk.
    expect((await sv.identify(prop('towels'), undefined, undefined, { runId: 'c' })).name).toContain('Towel');
    expect((await sv.identify(gray, undefined, undefined, { runId: 'c' })).name).toBe('2% Milk');
  });
  it('reads the receipt', async () => {
    const lines = await v.readReceipt('');
    expect(lines).toHaveLength(3);
    expect(lines.reduce((s, l) => s + l.cents, 0)).toBe(3700);
  });
});

describe('StubPrice and seed', () => {
  it('prices the table and nothing else', async () => {
    const p = new StubPrice();
    expect((await p.lookup('Kirkland Eggs 24 ct', 'costco'))?.cents).toBe(872);
    expect(await p.lookup('mochi', 'costco')).toBeNull();
  });
  it('seeds a run with only the shopper', () => {
    const r = seedRun(0);
    expect(r.people).toHaveLength(1);
    expect(r.people[0]).toMatchObject({ name: 'Jake', isShopper: true, payoutPan: '4111111111111111' });
    expect(r.chips).toHaveLength(0);
    expect(r.store).toBe('costco');
    expect(r.taxRate).toBe(0);
  });
  it('selects providers by env and rejects unknown', () => {
    expect(getVision()).toBeInstanceOf(StubVision);
    expect(getDetector()).toBeInstanceOf(DiffDetector);
    expect(getPrice()).toBeInstanceOf(StubPrice);
    process.env.VISION = 'nope';
    expect(() => getVision()).toThrow();
    delete process.env.VISION;
  });
});

describe('DiffDetector', () => {
  it('emits changing while moving and exactly one newItem once still', async () => {
    const d = new DiffDetector({ settleMs: 1000, minChangedFraction: 0.04 });
    let t = 0;
    const push = (n: string, step = 500): Promise<DetectEvent[]> => d.push({ jpegBase64: frame(n), at: (t += step) });
    for (let i = 0; i < 6; i++) expect(await push('empty')).toEqual([]);
    expect(await push('eggs-moving1')).toEqual([{ kind: 'changing' }]);
    expect(await push('eggs-moving2')).toEqual([{ kind: 'changing' }]);
    const stillAt: number[] = [];
    const events: DetectEvent[] = [];
    for (let i = 0; i < 3; i++) {
      events.push(...(await push('eggs-still')));
      stillAt.push(t);
    }
    const items = events.filter((e) => e.kind === 'newItem');
    expect(items).toHaveLength(1);
    const item = items[0] as Extract<DetectEvent, { kind: 'newItem' }>;
    expect(item.at).toBe(stillAt[2]);
    expect(item.region.x).toBeLessThanOrEqual(220);
    expect(item.region.y).toBeLessThanOrEqual(180);
    expect(item.region.x + item.region.w).toBeGreaterThanOrEqual(420);
    expect(item.region.y + item.region.h).toBeGreaterThanOrEqual(380);
    expect(item.region.w).toBeLessThan(260);
    expect(item.frameBase64.length).toBeGreaterThan(0);
    expect(await push('eggs-still')).toEqual([]);
    expect(await push('eggs-still')).toEqual([]);
  });

  it('ignores a change that disappears before settling', async () => {
    const d = new DiffDetector({ settleMs: 1000, minChangedFraction: 0.04 });
    await d.push({ jpegBase64: frame('empty'), at: 0 });
    expect(await d.push({ jpegBase64: frame('eggs-still'), at: 500 })).toEqual([{ kind: 'changing' }]);
    expect(await d.push({ jpegBase64: frame('empty'), at: 1000 })).toEqual([]);
    expect(await d.push({ jpegBase64: frame('empty'), at: 2500 })).toEqual([]);
  });

  it('re-baselines on a whole-frame lighting shift and emits no newItem', async () => {
    const d = new DiffDetector({ settleMs: 1000, minChangedFraction: 0.04 });
    const bright = (await sharp(Buffer.from(frame('empty'), 'base64')).modulate({ brightness: 1.6 }).jpeg().toBuffer()).toString('base64');
    await d.push({ jpegBase64: frame('empty'), at: 0 });
    const events: DetectEvent[] = [];
    for (let t = 500; t <= 4000; t += 500) events.push(...(await d.push({ jpegBase64: bright, at: t })));
    expect(events.filter((e) => e.kind === 'newItem')).toEqual([]);
    // The bright frame is now the baseline: no further change.
    expect(await d.push({ jpegBase64: bright, at: 4500 })).toEqual([]);
  });

  it('decodes a frame sharp can produce', async () => {
    expect((await sharp(Buffer.from(frame('empty'), 'base64')).metadata()).width).toBe(640);
  });
});
