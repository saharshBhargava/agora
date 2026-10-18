import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { seedRun } from '../src/seed.js';
import { createStore } from '../src/store.js';

describe('store load', () => {
  it('drops chips that were still identifying when the server stopped', () => {
    const dir = mkdtempSync(join(tmpdir(), 'dibs-load-'));
    const run = seedRun(0);
    const base = { priceSource: 'none', photoUrl: null, region: null, quantity: 1, claimers: [], wishedBy: null, duplicateOf: null, putBack: false, dropped: false, overCap: [], removedAt: null, addedAt: 0 };
    const chips = [
      { ...base, id: 'a', name: '', priceCents: null, state: 'identifying' },
      { ...base, id: 'b', name: 'Apple', priceCents: 110, state: 'open' },
    ];
    writeFileSync(join(dir, 'runs.json'), JSON.stringify({ [run.id]: { ...run, chips } }));
    const store = createStore(dir);
    expect(store.get(run.id)!.chips.map((c) => c.id)).toEqual(['b']);
  });
});
