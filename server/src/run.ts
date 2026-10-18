// Pure run and chip state machines. Immutable updates, `now` injected, no I/O.
import { capAllows, roomFor, splitChip } from './money.js';
import type { Chip, ChipState, Person, Run } from './types.js';

type NewChip = Pick<Chip, 'id' | 'name' | 'priceCents' | 'priceSource' | 'photoUrl' | 'region' | 'quantity'>;
type Err<E extends string> = { error: E };

const UNDO_MS = 5000;
const DUPLICATE_MS = 5000;

const normalize = (name: string): string => name.toLowerCase().trim().replace(/\s+/g, ' ').replace(/[^a-z0-9]/g, '');
const accepting = (run: Run): boolean => run.state === 'open' || run.state === 'lastCall';
/** The shopper can still fix a chip's name or price up to and including locked. */
export const fixable = (run: Run): boolean => accepting(run) || run.state === 'locked';
const person = (run: Run, id: string): Person | undefined => run.people.find((p) => p.id === id);
const hasClaims = (c: Chip): boolean => c.state !== 'removed' && !c.putBack;

const mapChip = (run: Run, id: string, fn: (c: Chip) => Chip): Run => ({
  ...run,
  chips: run.chips.map((c) => (c.id === id ? fn(c) : c)),
});

/** Full prices of the priced chips in a person's tray (unpriced count nothing). */
function trayPrices(run: Run, personId: string, exceptChipId?: string): number[] {
  return run.chips
    .filter((c) => c.id !== exceptChipId && hasClaims(c) && c.claimers.includes(personId) && c.priceCents !== null)
    .map((c) => c.priceCents as number);
}

/** True when the person's tray, with this chip at its current price, fits their authorization. */
function fits(run: Run, chip: Chip, personId: string): boolean {
  const p = person(run, personId);
  if (!p) return false;
  if (p.isShopper) return true;
  if (p.authorizedCents === null) return false;
  const tray = trayPrices(run, personId, chip.id);
  return capAllows(tray, chip.priceCents ?? 0, p.authorizedCents, run.taxRate);
}

const claimedState = (c: Chip): ChipState => (c.claimers.length > 0 ? 'claimed' : 'open');

/** Recompute `overCap` for one chip over its claimers and previous overCap members. */
function refreshOverCap(run: Run, chipId: string): Run {
  const chip = run.chips.find((c) => c.id === chipId);
  if (!chip) return run;
  const ids = [...new Set([...chip.claimers, ...chip.overCap])];
  const overCap = ids.filter((id) => !fits(run, chip, id));
  return mapChip(run, chipId, (c) => ({ ...c, overCap }));
}

/** Replace an open wish with the same name by `chip`, giving the wisher a claim if the cap allows. */
function resolveWish(run: Run, chip: Chip): Run {
  const key = normalize(chip.name);
  const w = key === '' ? undefined : run.chips.find((c) => c.state === 'wish' && normalize(c.name) === key);
  const without = run.chips.filter((c) => c !== w);
  if (!w) return { ...run, chips: run.chips.map((c) => (c.id === chip.id ? chip : c)) };
  const wisher = w.wishedBy ?? run.shopperId;
  const claims = fits({ ...run, chips: without }, chip, wisher);
  const resolved: Chip = claims
    ? { ...chip, claimers: [...chip.claimers, wisher], state: 'claimed' }
    : { ...chip, overCap: [...chip.overCap, wisher] };
  // Keep the wish's slot in the grid for the chip that replaces it.
  const exists = run.chips.some((c) => c.id === chip.id);
  const chips = exists
    ? without.map((c) => (c.id === chip.id ? resolved : c))
    : run.chips.map((c) => (c === w ? resolved : c));
  return { ...run, chips };
}

export function createRun(
  shopper: Omit<Person, 'isShopper' | 'authorizedCents' | 'authId' | 'approvalCode'>,
  store: string,
  payoutPan: string,
  now: number,
): Run {
  void now;
  return {
    id: crypto.randomUUID(),
    state: 'open',
    store,
    shopperId: shopper.id,
    people: [{ ...shopper, isShopper: true, authorizedCents: null, authId: null, approvalCode: null, payoutPan }],
    chips: [],
    taxRate: 0,
    lastCallEndsAt: null,
    receipt: null,
    settle: {},
    payout: null,
  };
}

/** The server authorizes first and never calls this on a decline. Re-joining replaces the person. */
export function join(run: Run, p: Person): Run | Err<'cart closed'> {
  if (!accepting(run)) return { error: 'cart closed' };
  const exists = run.people.some((x) => x.id === p.id);
  return { ...run, people: exists ? run.people.map((x) => (x.id === p.id ? p : x)) : [...run.people, p] };
}

export function setAuthorization(run: Run, personId: string, authorizedCents: number, authId: string, approvalCode: string | null = null): Run {
  let next: Run = {
    ...run,
    people: run.people.map((p) => (p.id === personId ? { ...p, authorizedCents, authId, approvalCode: approvalCode ?? p.approvalCode } : p)),
  };
  for (const c of run.chips) next = refreshOverCap(next, c.id);
  return next;
}

/** Returns the run unchanged once locked. */
export function addChip(run: Run, input: NewChip, now: number): Run {
  if (!accepting(run)) return run;
  const key = normalize(input.name);
  const dup = key === '' ? undefined : run.chips.find(
    (c) => c.state !== 'wish' && c.state !== 'removed' && normalize(c.name) === key && now - c.addedAt <= DUPLICATE_MS,
  );
  const chip: Chip = {
    ...input,
    claimers: [],
    state: key === '' ? 'identifying' : 'open',
    wishedBy: null,
    duplicateOf: dup ? dup.id : null,
    putBack: false,
    dropped: false,
    overCap: [],
    removedAt: null,
    addedAt: now,
  };
  return key === '' ? { ...run, chips: [...run.chips, chip] } : resolveWish({ ...run, chips: [...run.chips, chip] }, chip);
}

export function setChipLive(
  run: Run,
  chipId: string,
  name: string,
  priceCents: number | null,
  priceSource: Chip['priceSource'],
  now: number,
): Run {
  const chip = run.chips.find((c) => c.id === chipId);
  if (!chip || chip.dropped || !accepting(run)) return run;
  // An identifying chip that gets a name is checked against live chips seen in the last 5 s.
  const key = normalize(name);
  const dup = chip.state !== 'identifying' || chip.duplicateOf || key === '' ? undefined : run.chips.find(
    (c) => c.id !== chipId && !c.dropped && c.state !== 'wish' && c.state !== 'removed' && c.state !== 'identifying' &&
      normalize(c.name) === key && now - c.addedAt <= DUPLICATE_MS,
  );
  const live: Chip = {
    ...chip,
    duplicateOf: dup ? dup.id : chip.duplicateOf,
    name,
    priceCents,
    priceSource,
    state: chip.state === 'identifying' ? (normalize(name) === '' ? 'identifying' : claimedState(chip)) : chip.state,
  };
  return resolveWish({ ...run, chips: run.chips.map((c) => (c.id === chipId ? live : c)) }, live);
}

/** Returns the run unchanged unless it is open, in last call or locked. */
export function setChipPrice(run: Run, chipId: string, priceCents: number | null, priceSource: Chip['priceSource']): Run {
  if (!fixable(run)) return run;
  return refreshOverCap(mapChip(run, chipId, (c) => ({ ...c, priceCents, priceSource })), chipId);
}

export function claim(
  run: Run,
  chipId: string,
  personId: string,
  now: number,
): Run | Err<'cart closed' | 'over cap' | 'unknown chip' | 'not claimable'> {
  void now;
  if (!accepting(run)) return { error: 'cart closed' };
  const chip = run.chips.find((c) => c.id === chipId);
  if (!chip) return { error: 'unknown chip' };
  if (chip.state !== 'open' && chip.state !== 'claimed') return { error: 'not claimable' };
  if (chip.claimers.includes(personId)) return run;
  if (!fits(run, chip, personId)) return { error: 'over cap' };
  return mapChip(run, chipId, (c) => ({
    ...c,
    claimers: [...c.claimers, personId],
    state: 'claimed',
    overCap: c.overCap.filter((id) => id !== personId),
  }));
}

export function leave(run: Run, chipId: string, personId: string): Run | Err<'cart closed' | 'unknown chip'> {
  if (!accepting(run)) return { error: 'cart closed' };
  const chip = run.chips.find((c) => c.id === chipId);
  if (!chip) return { error: 'unknown chip' };
  if (!chip.claimers.includes(personId)) return run;
  return mapChip(run, chipId, (c) => {
    const claimers = c.claimers.filter((id) => id !== personId);
    return { ...c, claimers, state: c.state === 'removed' ? 'removed' : claimers.length > 0 ? c.state : 'open', overCap: c.overCap.filter((id) => id !== personId) };
  });
}

/**
 * Returns the run unchanged once locked. A wish is deleted outright (no undo);
 * any other chip becomes `removed` with its claims intact.
 */
export function removeChip(run: Run, chipId: string, now: number): Run {
  if (!accepting(run)) return run;
  const chip = run.chips.find((c) => c.id === chipId);
  if (!chip) return run;
  if (chip.state === 'wish') return { ...run, chips: run.chips.filter((c) => c.id !== chipId) };
  if (chip.state === 'removed') return run;
  return mapChip(run, chipId, (c) => ({ ...c, state: 'removed', removedAt: now }));
}

export function undoRemove(run: Run, chipId: string, now: number): Run | Err<'undo expired'> {
  const chip = run.chips.find((c) => c.id === chipId);
  if (!accepting(run) || !chip || chip.state !== 'removed' || chip.removedAt === null || now - chip.removedAt > UNDO_MS) {
    return { error: 'undo expired' };
  }
  return mapChip(run, chipId, (c) => ({
    ...c,
    state: normalize(c.name) === '' ? 'identifying' : claimedState(c),
    removedAt: null,
  }));
}

/** Returns the run unchanged once locked. `wishedBy` is null for the shopper. */
export function wish(run: Run, personId: string, name: string, now: number, id: string = crypto.randomUUID()): Run {
  if (!accepting(run)) return run;
  const chip: Chip = {
    id,
    name,
    priceCents: null,
    priceSource: 'none',
    photoUrl: null,
    region: null,
    quantity: 1,
    claimers: [],
    state: 'wish',
    wishedBy: personId === run.shopperId ? null : personId,
    duplicateOf: null,
    putBack: false,
    dropped: false,
    overCap: [],
    removedAt: null,
    addedAt: now,
  };
  return { ...run, chips: [...run.chips, chip] };
}

/** Shopper only (enforced by the server). Returns the run unchanged unless it is open, in last call or locked. */
export function fixChip(run: Run, chipId: string, name: string | undefined, priceCents: number | undefined, now: number): Run {
  const chip = run.chips.find((c) => c.id === chipId);
  if (!chip || !fixable(run)) return run;
  const source: Chip['priceSource'] = priceCents === undefined ? chip.priceSource : 'sticker';
  const price = priceCents === undefined ? chip.priceCents : priceCents;
  if (name !== undefined && chip.state === 'identifying') return setChipLive(run, chipId, name, price, price === null ? 'none' : source, now);
  let next = name !== undefined ? mapChip(run, chipId, (c) => ({ ...c, name })) : run;
  if (priceCents !== undefined) next = setChipPrice(next, chipId, priceCents, 'sticker');
  return next;
}

export function checkout(run: Run, now: number, lastCallMs: number): Run {
  if (run.state !== 'open') return run;
  return { ...run, state: 'lastCall', lastCallEndsAt: now + lastCallMs };
}

export function lock(run: Run, now: number): Run {
  if (run.state !== 'lastCall' || run.lastCallEndsAt === null || now < run.lastCallEndsAt) return run;
  return {
    ...run,
    state: 'locked',
    chips: run.chips.map((c) => {
      if (c.state === 'identifying') return { ...c, dropped: true };
      if (c.state === 'open' || c.state === 'claimed') return { ...c, state: 'locked' };
      return c;
    }),
  };
}

export function backToCart(run: Run): Run {
  if (run.state !== 'lastCall' && run.state !== 'locked') return run;
  return {
    ...run,
    state: 'open',
    lastCallEndsAt: null,
    chips: run.chips.map((c) => ({
      ...c,
      putBack: false,
      dropped: false,
      state: c.state === 'locked' ? claimedState(c) : c.state,
    })),
  };
}

/** Only when locked; otherwise the run is returned unchanged. */
export function putBack(run: Run, chipId: string): Run {
  if (run.state !== 'locked') return run;
  return mapChip(run, chipId, (c) => ({ ...c, putBack: true }));
}

/** Each person's share across claimed, non-removed, non-put-back, priced chips (everyone present, 0 if none). */
export function sharesFor(run: Run): Map<string, number> {
  const out = new Map<string, number>(run.people.map((p) => [p.id, 0]));
  for (const c of run.chips) {
    if (!hasClaims(c) || c.dropped || c.priceCents === null || c.state === 'wish' || c.state === 'identifying') continue;
    for (const [id, cents] of splitChip(c.priceCents, c.claimers)) out.set(id, (out.get(id) ?? 0) + cents);
  }
  return out;
}

/** Room for every person with an authorization (the shopper has none and is omitted). */
export function roomsFor(run: Run): Map<string, number> {
  const out = new Map<string, number>();
  for (const p of run.people) {
    if (p.authorizedCents !== null) out.set(p.id, roomFor(trayPrices(run, p.id), p.authorizedCents, run.taxRate));
  }
  return out;
}

/** Live chips with no claimers: excludes wishes, removed, dropped and put-back chips. */
export function unclaimed(run: Run): Chip[] {
  return run.chips.filter((c) => c.claimers.length === 0 && c.state !== 'wish' && hasClaims(c) && !c.dropped);
}
