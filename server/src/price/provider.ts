import { StubPrice } from './stub.js';

export interface PriceProvider {
  lookup(name: string, store: string): Promise<{ cents: number; sourceUrl: string } | null>;
}

export function getPrice(): PriceProvider {
  const mode = process.env.PRICE ?? 'stub';
  if (mode === 'stub') return new StubPrice();
  throw new Error(`PRICE=${mode} is not wired yet`);
}
