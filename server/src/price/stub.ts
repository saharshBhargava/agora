import type { PriceProvider } from './provider.js';

export const PROPS = [
  { key: 'eggs', name: 'Kirkland Eggs 24 ct', cents: 872, words: ['egg'] },
  { key: 'towels', name: 'Paper Towels 12 pk', cents: 2399, words: ['towel'] },
  { key: 'milk', name: '2% Milk', cents: 429, words: ['milk'] },
] as const;

export class StubPrice implements PriceProvider {
  async lookup(name: string, _store: string): Promise<{ cents: number; sourceUrl: string } | null> {
    const n = name.toLowerCase();
    const p = PROPS.find((x) => x.words.some((w) => n.includes(w)));
    return p ? { cents: p.cents, sourceUrl: `stub://${p.key}` } : null;
  }
}
