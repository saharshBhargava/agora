import { randomUUID } from 'node:crypto';
import type { PriceProvider } from './provider.js';

export type PriceRequest = { id: string; name: string; store: string; createdAt: number };

type Pending = { req: PriceRequest; done: (r: { cents: number; sourceUrl: string } | null) => void; timer: ReturnType<typeof setTimeout> };

/** Queues price lookups for a browser worker (the shopper's phone) to answer. */
export class AgentPrice implements PriceProvider {
  private readonly pending = new Map<string, Pending>();
  private readonly timeoutMs: number;

  constructor(opts: { timeoutMs?: number } = {}) {
    this.timeoutMs = opts.timeoutMs ?? 45_000;
  }

  lookup(name: string, store: string): Promise<{ cents: number; sourceUrl: string } | null> {
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
    p.done({ cents: r.cents, sourceUrl: r.url });
    return true;
  }
}
