'use client';
import { useEffect, useState } from 'react';
import type { Box, Chip } from './types';
import { formatCents } from './money';

const SHOW_MS = 8000;

export type Highlight = { region: Box; label: string; pending: boolean };

/**
 * What to outline over the live picture: the region being identified right now, or else the newest chip
 * that came with a region, labelled "<name> · $price", for a few seconds after it lands.
 */
export function useHighlight(chips: Chip[], identifyingRegion: Box | null): Highlight | null {
  const newest = chips
    .filter((c) => c.region && c.state !== 'wish' && c.state !== 'identifying' && c.state !== 'removed' && !c.dropped)
    .sort((a, b) => b.addedAt - a.addedAt)[0];
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!newest) return;
    const left = newest.addedAt + SHOW_MS - Date.now();
    setNow(Date.now());
    if (left <= 0) return;
    const t = setTimeout(() => setNow(Date.now()), left + 50);
    return () => clearTimeout(t);
  }, [newest?.id, newest?.addedAt]); // eslint-disable-line react-hooks/exhaustive-deps

  if (identifyingRegion) return { region: identifyingRegion, label: 'Identifying…', pending: true };
  if (newest?.region && now - newest.addedAt < SHOW_MS) {
    const price = newest.priceCents === null ? '~$?' : formatCents(newest.priceCents);
    return { region: newest.region, label: `${newest.name} · ${price}`, pending: false };
  }
  return null;
}
