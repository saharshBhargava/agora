import { randomUUID } from 'node:crypto';
import type { PriceProvider } from './provider.js';

export type PriceRequest = { id: string; name: string; store: string; createdAt: number };

type Pending = { req: PriceRequest; done: (r: { cents: number; sourceUrl: string } | null) => void; timer: ReturnType<typeof setTimeout> };

/** Queues price lookups for a browser worker (the shopper's phone) to answer. */
export class AgentPrice implements PriceProvider {
  private readonly pending = new Map<string, Pending>();
  private readonly cache = new Map<string, { cents: number; sourceUrl: string; at: number }>();
  private readonly timeoutMs: number;

  constructor(opts: { timeoutMs?: number } = {}) {
    this.timeoutMs = opts.timeoutMs ?? 120_000;
  }

  lookup(name: string, store: string): Promise<{ cents: number; sourceUrl: string } | null> {
    // The same product seen again (another unit, a re-detection) prices instantly.
    const hit = this.cache.get(cacheKey(name, store));
    if (hit && Date.now() - hit.at < CACHE_MS) return Promise.resolve({ cents: hit.cents, sourceUrl: hit.sourceUrl });
    return new Promise((done) => {
      const req: PriceRequest = { id: randomUUID(), name, store, createdAt: Date.now() };
      const timer = setTimeout(() => {
        this.pending.delete(req.id);
        done(null);
      }, this.timeoutMs);
      this.pending.set(req.id, { req, done, timer });
    });
  }

  open(): PriceRequest[] {
    return [...this.pending.values()].map((p) => p.req);
  }

  get(id: string): PriceRequest | undefined {
    return this.pending.get(id)?.req;
  }

  /** Resolves a pending lookup; false when the id is unknown or expired. */
  resolve(id: string, r: { cents: number; url: string }): boolean {
    const p = this.pending.get(id);
    if (!p) return false;
    clearTimeout(p.timer);
    this.pending.delete(id);
    this.cache.set(cacheKey(p.req.name, p.req.store), { cents: r.cents, sourceUrl: r.url, at: Date.now() });
    p.done({ cents: r.cents, sourceUrl: r.url });
    return true;
  }
}

/** How long a found price is reused for the same product at the same store. */
const CACHE_MS = 30 * 60 * 1000;

const cacheKey = (name: string, store: string): string =>
  `${store.trim().toLowerCase()}|${name.trim().toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()}`;
