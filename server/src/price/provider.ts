import { GeminiPrice } from './gemini.js';
import { StubPrice } from './stub.js';

export interface PriceProvider {
  lookup(name: string, store: string): Promise<{ cents: number; sourceUrl: string } | null>;
}

export function getPrice(): PriceProvider {
  const mode = process.env.PRICE ?? 'stub';
  if (mode === 'stub') return new StubPrice();
  if (mode === 'gemini') {
    if (!process.env.GEMINI_API_KEY) throw new Error('PRICE=gemini requires GEMINI_API_KEY');
    return new GeminiPrice();
  }
  throw new Error(`PRICE=${mode} is not wired yet`);
}
