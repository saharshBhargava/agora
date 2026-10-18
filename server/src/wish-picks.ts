// GET /api/runs/:id/wish-picks: what the "+ Wish" page offers. The household's shopping list and
// suggestions come from the team backend when it is configured (src/team/backend.ts), read as the signed-in
// person when the app sends their token (X-Household-Token) and as the demo account otherwise; suggestions
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

/**
 * The household's lists and suggestions. `token` is the signed-in person's own team-API bearer token, when they
 * sent one: it is that person's household, and never anyone else's. Rejects when they can't be had; the caller
 * falls back.
 */
export interface HouseholdSource {
  picks(token?: string): Promise<HouseholdPicks>;
}

/** The comparison key for an item name: the same rule as `normalize` in run.ts. */
export const pickKey = (name: string): string =>
  name.toLowerCase().trim().replace(/\s+/g, ' ').replace(/[^a-z0-9]/g, '');

// Sizes, counts and filler say nothing about which product it is: "75 ct", "12 fl oz", "of".
const FILLER = new Set(['the', 'a', 'an', 'of', 'and', 'with', 'each', 'oz', 'fl', 'ct', 'count', 'lb', 'lbs', 'pk', 'pack', 'g', 'kg', 'ml']);

/** The words that name a product, lowercased, without sizes or filler, plurals folded ("towels" → "towel"). */
export function productWords(name: string): Set<string> {
  return new Set(
    name.toLowerCase().replace(/[®™©]/g, '').split(/[^a-z0-9]+/)
      .filter((w) => w.length > 1 && !/^\d/.test(w) && !FILLER.has(w))
      .map((w) => (w.length > 3 && w.endsWith('s') && !w.endsWith('ss') ? w.slice(0, -1) : w)),
  );
}

/**
 * Whether two names are one product for suggesting: every word of the shorter name is in the longer one.
 * "Clorox Disinfecting Wipes" and "Clorox Disinfecting Wipes Fresh Scent 75 ct" are; "Honeycrisp Apple" and
 * "Cosmic Crisp Apple" are not.
 */
export function sameProduct(a: string, b: string): boolean {
  const x = productWords(a);
  const y = productWords(b);
  if (x.size === 0 || y.size === 0) return pickKey(a) === pickKey(b);
  const [small, big] = x.size <= y.size ? [x, y] : [y, x];
  for (const w of small) if (!big.has(w)) return false;
  return true;
}

const inCart = (c: Run['chips'][number]): boolean =>
  c.state !== 'wish' && c.state !== 'removed' && c.state !== 'identifying' && !c.dropped && !c.putBack;

/** "QFC" from "qfc" or "QFC", "Costco" from "costco". */
export function storeLabel(store: string): string {
  const s = store.trim();
  if (/^[a-z]{1,4}$/.test(s)) return s.toUpperCase();
  return s ? s[0]!.toUpperCase() + s.slice(1) : '';
}

/** When a run happened: its newest chip (runs keep no creation time). */
const runTime = (r: Run): number => r.chips.reduce((t, c) => Math.max(t, c.addedAt), 0);

/** The names of everything in this run's cart or wished for. */
const namedInRun = (run: Run): string[] =>
  run.chips.filter((c) => (inCart(c) || c.state === 'wish') && pickKey(c.name)).map((c) => c.name);

/**
 * Source B: the items bought most often in this store's other runs, minus anything already named in
 * this run. Bought means it made it into the cart (not a wish, not removed, dropped or put back).
 * Names of one product ("... 75 Count", "... 75 ct") count as one pick under its most recent name.
 */
export function historyPicks(runs: Run[], run: Run, max = MAX_PICKS): WishSuggestion[] {
  const storeKey = pickKey(run.store);
  const named = namedInRun(run);
  const past = runs.filter((r) => r.id !== run.id && pickKey(r.store) === storeKey && r.chips.some(inCart));
  const last = past.reduce<Run | null>((best, r) => (best && runTime(best) >= runTime(r) ? best : r), null);
  const seen: { names: string[]; name: string; count: number; at: number; inLast: boolean; lastRun: string }[] = [];
  for (const r of past) {
    const at = runTime(r);
    for (const c of r.chips) {
      if (!inCart(c) || !pickKey(c.name) || named.some((n) => sameProduct(n, c.name))) continue;
      const name = cleanText(c.name, MAX_NAME);
      const prev = seen.find((s) => s.names.some((n) => sameProduct(n, c.name)));
      if (!prev) {
        seen.push({ names: [c.name], name, count: 1, at, inLast: r === last, lastRun: r.id });
        continue;
      }
      prev.names.push(c.name);
      if (prev.lastRun === r.id) continue; // counted once per run
      prev.lastRun = r.id;
      if (at >= prev.at) prev.name = name;
      prev.count += 1;
      prev.at = Math.max(at, prev.at);
      prev.inLast ||= r === last;
    }
  }
  const label = storeLabel(run.store);
  return seen
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
  const cartNames = run.chips.filter((c) => inCart(c) && pickKey(c.name)).map((c) => c.name);
  const named = namedInRun(run);
  const storeKey = pickKey(run.store);
  const lists = (household?.lists ?? []).filter((l) => l.items.length > 0);
  const atStore = (l: HouseholdList) => !!storeKey && !!l.store && pickKey(l.store) === storeKey;
  const chosen = [...lists].sort((a, b) => Number(atStore(b)) - Number(atStore(a)) || b.updatedAt - a.updatedAt)[0];

  let list: WishList | null = null;
  const onList = new Set<string>();
  const listNames: string[] = [];
  if (chosen) {
    const items: WishListItem[] = [];
    for (const item of chosen.items) {
      const key = pickKey(item.name);
      if (!key || onList.has(key)) continue;
      onList.add(key);
      listNames.push(item.name);
      if (!cartNames.some((n) => sameProduct(n, item.name)) && items.length < MAX_PICKS) items.push(item);
    }
    list = { name: chosen.name, store: chosen.store, items };
  }

  const suggestions: WishSuggestion[] = [];
  const taken: string[] = [];
  for (const s of [...(household?.suggestions ?? []), ...history]) {
    if (!pickKey(s.name)) continue;
    if ([...taken, ...named, ...listNames].some((n) => sameProduct(n, s.name))) continue;
    taken.push(s.name);
    suggestions.push(s);
    if (suggestions.length >= MAX_PICKS) break;
  }
  return { list, suggestions };
}

/** The household's picks, or null when there is no source or it failed (it logs its own failures). */
export async function householdPicks(source: HouseholdSource | null, token?: string): Promise<HouseholdPicks | null> {
  if (!source) return null;
  try {
    return await source.picks(token);
  } catch {
    return null;
  }
}
