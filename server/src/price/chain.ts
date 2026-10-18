import type { PriceProvider } from './provider.js';

/** Tries each provider in order and returns the first non-null price. */
export function chain(providers: PriceProvider[]): PriceProvider {
  return {
    async lookup(name, store) {
      for (const p of providers) {
        const r = await p.lookup(name, store);
        if (r) return r;
      }
      return null;
    },
  };
}
