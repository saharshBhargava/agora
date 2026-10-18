import { AgentPrice } from './agent.js';
import { chain } from './chain.js';
import { GeminiPrice } from './gemini.js';
import { StubPrice } from './stub.js';

export interface PriceProvider {
  lookup(name: string, store: string): Promise<{ cents: number; sourceUrl: string } | null>;
}

export type PriceSetup = { provider: PriceProvider; agent?: AgentPrice };

/** PRICE is a comma list of gemini, agent, stub, tried in order. */
export function getPriceSetup(): PriceSetup {
  const modes = (process.env.PRICE ?? 'stub').split(',').map((m) => m.trim()).filter(Boolean);
  if (modes.length === 0) modes.push('stub');
  let agent: AgentPrice | undefined;
  const providers = modes.map((mode): PriceProvider => {
    if (mode === 'stub') return new StubPrice();
    if (mode === 'gemini') {
      if (!process.env.GEMINI_API_KEY) throw new Error('PRICE=gemini requires GEMINI_API_KEY');
      return new GeminiPrice();
    }
    if (mode === 'agent') {
      agent ??= new AgentPrice();
      return agent;
    }
    throw new Error(`PRICE=${mode} is not wired yet`);
  });
  return { provider: providers.length === 1 ? providers[0] : chain(providers), agent };
}

export function getPrice(): PriceProvider {
  return getPriceSetup().provider;
}
