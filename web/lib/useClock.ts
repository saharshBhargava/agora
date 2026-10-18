'use client';
import { useEffect, useState } from 'react';
import type { Chip } from './types';
import { NO_PRICE_MS } from './visible';

/**
 * The current time, ticking once a second only while some named chip is still waiting on a price,
 * so time-based feed rules (show after 5 s, "Add price" after 20 s) take effect without a new broadcast.
 */
export function useClock(chips: Chip[] | undefined): number {
  const [now, setNow] = useState(() => Date.now());
  const waiting = (chips ?? []).some(
    (c) => c.priceCents === null && c.name.trim() !== '' && c.state !== 'wish' && c.state !== 'removed' && Date.now() - c.addedAt < NO_PRICE_MS + 1000,
  );
  useEffect(() => {
    if (!waiting) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [waiting]);
  return now;
}
