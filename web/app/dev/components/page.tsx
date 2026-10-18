'use client';
// Throwaway preview of Grid + Tray with mock data. Not part of the product.
import { useState } from 'react';
import { Board } from '@/components/Board';
import type { Chip, Person } from '@/lib/types';

const person = (id: string, name: string, shopper = false): Person => ({
  id, name, initial: name[0], isShopper: shopper, authorizedCents: shopper ? null : 4000, authId: null, payoutPan: null,
});
const people = [person('j', 'Jake', true), person('a', 'Anson'), person('b', 'Bea'), person('c', 'Cy'), person('d', 'Dee'), person('e', 'Eli')];
const mk = (o: Partial<Chip> & { id: string; name: string }): Chip => ({
  priceCents: 100, priceSource: 'sticker', photoUrl: null, region: null, quantity: 1, claimers: [], state: 'open',
  wishedBy: null, duplicateOf: null, putBack: false, dropped: false, overCap: [], removedAt: null, addedAt: 0, ...o,
});
const initial: Chip[] = [
  mk({ id: 'eggs', name: 'Kirkland Eggs 24 ct', priceCents: 872, claimers: ['b', 'c'], state: 'claimed', addedAt: 1 }),
  mk({ id: 'towels', name: 'Paper Towels', priceCents: 2399, claimers: ['b'], state: 'claimed', addedAt: 2 }),
  mk({ id: 'milk', name: 'Milk', priceCents: 429, addedAt: 3 }),
  mk({ id: 'bagels', name: 'Bagels', priceCents: null, state: 'wish', wishedBy: 'b', addedAt: 4 }),
  mk({ id: 'mystery', name: 'Mystery Jar', priceCents: null, addedAt: 5, priceSource: 'none' }),
  mk({ id: 'party', name: 'Party Chips', priceCents: 999, claimers: ['a', 'b', 'c', 'd', 'e'], state: 'claimed', addedAt: 6 }),
  mk({ id: 'butter', name: 'Butter x2', priceCents: 1198, quantity: 2, addedAt: 7 }),
  mk({ id: 'rice', name: 'Rice', priceCents: 1299, addedAt: 8 }),
];

export default function Page() {
  const [chips, setChips] = useState(initial);
  const [log, setLog] = useState('');
  const me = 'a';
  const toggle = (id: string, claim: boolean) => {
    setLog(`${claim ? 'claim' : 'leave'} ${id}`);
    setChips((cs) => cs.map((c) => {
      if (c.id !== id) return c;
      const claimers = claim ? [...c.claimers.filter((x) => x !== me), me] : c.claimers.filter((x) => x !== me);
      return { ...c, claimers, state: claimers.length ? 'claimed' : 'open' };
    }));
  };
  return (
    <main className="screen" style={{ paddingBottom: 170 }}>
      <h1>Components</h1>
      <p className="muted" data-testid="log">{log || 'no events'}</p>
      <Board chips={chips} people={people} me={me} authorizedCents={4000} taxRate={0}
        onClaim={(id) => toggle(id, true)} onLeave={(id) => toggle(id, false)} />
    </main>
  );
}
