// GET /api/runs/:id/wish-picks: what the "+ Wish" page offers. The household's shopping list and
// suggestions come from the team backend when it is configured (src/team/backend.ts); suggestions
// always also draw on this server's own run history, which is all there is when the backend is
// unset or down.
import { cleanText } from './team/clean.js';
import type { Run } from './types.js';

export type WishListItem = { name: string; detail: string };
export type WishList = { name: string; store: string | null; items: WishListItem[] };
export type WishSuggestion = { name: string; reason: string };
export type WishPicks = { list: WishList | null; suggestions: WishSuggestion[] };

/** At most this many list items and this many suggestions. */
export const MAX_PICKS = 12;
export const MAX_NAME = 80;

/** One of the household's hand-made lists, with its open (unchecked) items. */
export type HouseholdList = WishList & { updatedAt: number };
/** Everything the household source knows, before it is fitted to one run. */
export type HouseholdPicks = { lists: HouseholdList[]; suggestions: WishSuggestion[] };

/** The household's lists and suggestions. Rejects when they can't be had; the caller falls back. */
export interface HouseholdSource {
  picks(): Promise<HouseholdPicks>;
}

/** The comparison key for an item name: the same rule as `normalize` in run.ts. */
export const pickKey = (name: string): string =>
  name.toLowerCase().trim().replace(/\s+/g, ' ').replace(/[^a-z0-9]/g, '');

const inCart = (c: Run['chips'][number]): boolean =>
  c.state !== 'wish' && c.state !== 'removed' && c.state !== 'identifying' && !c.dropped && !c.putBack;

/** Keys of the items in the cart, and of everything named in the run (the cart plus wishes). */
export function runKeys(run: Run): { cart: Set<string>; named: Set<string> } {
  const cart = new Set<string>();
  const named = new Set<string>();
  for (const c of run.chips) {
    const key = pickKey(c.name);
    if (!key) continue;
    if (inCart(c)) cart.add(key);
    if (inCart(c) || c.state === 'wish') named.add(key);
  }
  return { cart, named };
}

/** "QFC" from "qfc" or "QFC", "Costco" from "costco". */
export function storeLabel(store: string): string {
  const s = store.trim();
  if (/^[a-z]{1,4}$/.test(s)) return s.toUpperCase();
  return s ? s[0]!.toUpperCase() + s.slice(1) : '';
}

/** When a run happened: its newest chip (runs keep no creation time). */
const runTime = (r: Run): number => r.chips.reduce((t, c) => Math.max(t, c.addedAt), 0);

/**
 * Source B: the items bought most often in this store's other runs, minus anything already named in
 * this run. Bought means it made it into the cart (not a wish, not removed, dropped or put back).
 */
export function historyPicks(runs: Run[], run: Run, max = MAX_PICKS): WishSuggestion[] {
  const storeKey = pickKey(run.store);
  const exclude = runKeys(run).named;
  const past = runs.filter((r) => r.id !== run.id && pickKey(r.store) === storeKey && r.chips.some(inCart));
  const last = past.reduce<Run | null>((best, r) => (best && runTime(best) >= runTime(r) ? best : r), null);
  const seen = new Map<string, { name: string; count: number; at: number; inLast: boolean }>();
  for (const r of past) {
    const at = runTime(r);
    const keys = new Set<string>();
    for (const c of r.chips) {
      const key = pickKey(c.name);
      if (!inCart(c) || !key || exclude.has(key) || keys.has(key)) continue;
      keys.add(key);
      const prev = seen.get(key);
      const name = cleanText(c.name, MAX_NAME);
      if (!prev) seen.set(key, { name, count: 1, at, inLast: r === last });
      else seen.set(key, { name: at >= prev.at ? name : prev.name, count: prev.count + 1, at: Math.max(at, prev.at), inLast: prev.inLast || r === last });
    }
  }
  const label = storeLabel(run.store);
  return [...seen.values()]
    .sort((a, b) => b.count - a.count || b.at - a.at || a.name.localeCompare(b.name))
    .slice(0, max)
    .map((s) => ({
      name: s.name,
      reason: s.count >= 2
        ? (label ? `Often in your ${label} runs` : 'Often in your runs')
        : s.inLast ? 'In your last run' : (label ? `In a past ${label} run` : 'In a past run'),
    }));
}

/**
 * The page for one run. The list is the household list for this store if there is one, else the one
 * changed most recently; its items already in the cart are left out (a wished one stays, and the app
 * marks it Wished). Suggestions are the household's, then the run history's, minus anything named in
 * the run or on the list.
 */
export function composePicks(run: Run, household: HouseholdPicks | null, history: WishSuggestion[]): WishPicks {
  const { cart, named } = runKeys(run);
  const storeKey = pickKey(run.store);
  const lists = (household?.lists ?? []).filter((l) => l.items.length > 0);
  const atStore = (l: HouseholdList) => !!storeKey && !!l.store && pickKey(l.store) === storeKey;
  const chosen = [...lists].sort((a, b) => Number(atStore(b)) - Number(atStore(a)) || b.updatedAt - a.updatedAt)[0];

  let list: WishList | null = null;
  const onList = new Set<string>();
  if (chosen) {
    const items: WishListItem[] = [];
    for (const item of chosen.items) {
      const key = pickKey(item.name);
      if (!key || onList.has(key)) continue;
      onList.add(key);
      if (!cart.has(key) && items.length < MAX_PICKS) items.push(item);
    }
    list = { name: chosen.name, store: chosen.store, items };
  }

  const suggestions: WishSuggestion[] = [];
  const taken = new Set<string>();
  for (const s of [...(household?.suggestions ?? []), ...history]) {
    const key = pickKey(s.name);
    if (!key || taken.has(key) || named.has(key) || onList.has(key)) continue;
    taken.add(key);
    suggestions.push(s);
    if (suggestions.length >= MAX_PICKS) break;
  }
  return { list, suggestions };
}

/** The household's picks, or null when there is no source or it failed (it logs its own failures). */
export async function householdPicks(source: HouseholdSource | null): Promise<HouseholdPicks | null> {
  if (!source) return null;
  try {
    return await source.picks();
  } catch {
    return null;
  }
}
