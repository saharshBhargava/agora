import { describe, expect, it } from 'vitest';
import {
  addChip, setChipLive, backToCart, checkout, claim, countAgain, createRun, fixChip, join, leave, liveSameName, lock,
  putBack, removeChip, roomsFor, setAuthorization, setChipPrice, setQuantity, sharesFor, undoRemove, unclaimed, wish,
} from '../src/run.js';
import type { Chip, Run } from '../src/types.js';

type Err = { error: string };
const ok = (r: Run | Err): Run => {
  if ('error' in r) throw new Error(`unexpected error: ${r.error}`);
  return r;
};
const chip = (id: string, name: string, priceCents: number | null) => ({
  id, name, priceCents, priceSource: priceCents === null ? ('none' as const) : ('sticker' as const),
  photoUrl: null, region: null, quantity: 1,
});
const get = (run: Run, id: string): Chip => run.chips.find((c) => c.id === id)!;
const person = (id: string, authorizedCents = 4000) => ({
  id, name: id, initial: id.toUpperCase(), isShopper: false, authorizedCents, authId: `auth-${id}`, approvalCode: '888888', payoutPan: null,
});

function seeded(): Run {
  let r = createRun({ id: 's', name: 'Sam', initial: 'S', payoutPan: null }, 'Costco', '4111111111111111', 0);
  r = ok(join(r, person('a')));
  r = ok(join(r, person('b')));
  r = addChip(r, chip('eggs', 'Eggs', 872), 0);
  r = addChip(r, chip('towels', 'Paper towels', 2399), 100);
  r = addChip(r, chip('towels2', 'Towels B', 2399), 200);
  r = addChip(r, chip('milk', 'Milk', 429), 300);
  return r;
}

describe('createRun / join', () => {
  it('creates an open run with the shopper', () => {
    const r = createRun({ id: 's', name: 'Sam', initial: 'S', payoutPan: null }, 'Costco', 'PAN', 0);
    expect(r.state).toBe('open');
    expect(r.people[0]).toMatchObject({ id: 's', isShopper: true, authorizedCents: null, payoutPan: 'PAN' });
    expect(r.shopperId).toBe('s');
    expect(r.taxRate).toBe(0);
  });
  it('refuses join after lock', () => {
    let r = checkout(seeded(), 1000, 50);
    r = lock(r, 1050);
    expect(join(r, person('c'))).toEqual({ error: 'cart closed' });
  });
  it('still allows join in last call', () => {
    const r = checkout(seeded(), 1000, 50);
    expect(ok(join(r, person('c'))).people).toHaveLength(4);
  });
});

describe('claim / leave', () => {
  it('is idempotent', () => {
    let r = ok(claim(seeded(), 'eggs', 'a', 1));
    r = ok(claim(r, 'eggs', 'a', 2));
    expect(get(r, 'eggs').claimers).toEqual(['a']);
    expect(get(r, 'eggs').state).toBe('claimed');
  });
  it('splits between two claimers', () => {
    let r = ok(claim(seeded(), 'eggs', 'a', 1));
    r = ok(claim(r, 'eggs', 'b', 2));
    expect(sharesFor(r).get('a')).toBe(436);
    expect(sharesFor(r).get('b')).toBe(436);
  });
  it('gives the share back when a claimer leaves', () => {
    let r = ok(claim(seeded(), 'eggs', 'a', 1));
    r = ok(claim(r, 'eggs', 'b', 2));
    r = ok(leave(r, 'eggs', 'b'));
    expect(sharesFor(r).get('a')).toBe(872);
    expect(roomsFor(r).get('a')).toBe(3128);
  });
  it('returns the chip to open when the last claimer leaves', () => {
    let r = ok(claim(seeded(), 'eggs', 'a', 1));
    r = ok(leave(r, 'eggs', 'a'));
    expect(get(r, 'eggs').state).toBe('open');
    expect(get(r, 'eggs').claimers).toEqual([]);
  });
  it('lets the shopper claim with no authorization', () => {
    const r = ok(claim(seeded(), 'towels', 's', 1));
    expect(get(r, 'towels').claimers).toEqual(['s']);
    expect(sharesFor(r).get('s')).toBe(2399);
  });
  it('refuses over cap, and allows it after setAuthorization raises the cap', () => {
    let r = ok(claim(seeded(), 'eggs', 'a', 1));
    r = ok(claim(r, 'towels', 'a', 2));
    expect(claim(r, 'towels2', 'a', 3)).toEqual({ error: 'over cap' });
    r = setAuthorization(r, 'a', 6000, 'auth-a2');
    expect(r.people.find((p) => p.id === 'a')).toMatchObject({ authorizedCents: 6000, authId: 'auth-a2' });
    expect(get(ok(claim(r, 'towels2', 'a', 3)), 'towels2').claimers).toEqual(['a']);
  });
  it('refuses a non-shopper without authorization', () => {
    let r = ok(join(seeded(), { ...person('c'), authorizedCents: null, authId: null }));
    expect(claim(r, 'milk', 'c', 1)).toEqual({ error: 'over cap' });
  });
  it('refuses wish and identifying chips and unknown chips', () => {
    let r = wish(seeded(), 'a', 'bagels', 5, 'w1');
    r = addChip(r, chip('mystery', '', null), 6);
    expect(claim(r, 'w1', 'b', 7)).toEqual({ error: 'not claimable' });
    expect(claim(r, 'mystery', 'b', 7)).toEqual({ error: 'not claimable' });
    expect(claim(r, 'nope', 'b', 7)).toEqual({ error: 'unknown chip' });
  });
  it('refuses claim and leave once locked', () => {
    let r = ok(claim(seeded(), 'eggs', 'a', 1));
    r = lock(checkout(r, 10, 50), 60);
    expect(claim(r, 'milk', 'a', 61)).toEqual({ error: 'cart closed' });
    expect(leave(r, 'eggs', 'a')).toEqual({ error: 'cart closed' });
  });
  it('leave on an unknown chip errors', () => {
    expect(leave(seeded(), 'nope', 'a')).toEqual({ error: 'unknown chip' });
  });
  it('still allows claim during last call', () => {
    const r = checkout(seeded(), 10, 50);
    expect(get(ok(claim(r, 'milk', 'a', 11)), 'milk').claimers).toEqual(['a']);
  });
});

describe('removeChip / undoRemove', () => {
  const claimedEggs = () => {
    let r = ok(claim(seeded(), 'eggs', 'a', 1));
    return ok(claim(r, 'eggs', 'b', 2));
  };
  it('restores claims within 5000 ms', () => {
    let r = removeChip(claimedEggs(), 'eggs', 1000);
    expect(get(r, 'eggs')).toMatchObject({ state: 'removed', removedAt: 1000 });
    expect(sharesFor(r).get('a')).toBe(0);
    r = ok(undoRemove(r, 'eggs', 5000));
    expect(get(r, 'eggs')).toMatchObject({ state: 'claimed', claimers: ['a', 'b'], removedAt: null });
  });
  it('expires after 5000 ms', () => {
    const r = removeChip(claimedEggs(), 'eggs', 1000);
    expect(undoRemove(r, 'eggs', 7000)).toEqual({ error: 'undo expired' });
  });
  it('restores an unclaimed chip to open', () => {
    const r = ok(undoRemove(removeChip(seeded(), 'milk', 0), 'milk', 10));
    expect(get(r, 'milk').state).toBe('open');
  });
  it('deletes a wish outright', () => {
    const r = removeChip(wish(seeded(), 'a', 'bagels', 0, 'w1'), 'w1', 1);
    expect(r.chips.find((c) => c.id === 'w1')).toBeUndefined();
  });
  it('locked: removeChip, addChip and wish return the run unchanged', () => {
    const r = lock(checkout(seeded(), 10, 50), 60);
    expect(removeChip(r, 'milk', 61)).toBe(r);
    expect(addChip(r, chip('x', 'X', 100), 61)).toBe(r);
    expect(wish(r, 'a', 'bagels', 61)).toBe(r);
  });
});

describe('addChip / wish', () => {
  it('marks a chip with no name as identifying', () => {
    const r = addChip(seeded(), chip('m', '', null), 400);
    expect(get(r, 'm').state).toBe('identifying');
  });
  it('sets duplicateOf for the same normalized name within 5000 ms', () => {
    let r = addChip(seeded(), chip('milk2', '  MILK! ', 429), 5300);
    expect(get(r, 'milk2').duplicateOf).toBe('milk');
    r = addChip(seeded(), chip('milk3', 'milk', 429), 5301);
    expect(get(r, 'milk3').duplicateOf).toBeNull();
  });
  it('wish then matching chip puts the wisher in claimers', () => {
    let r = wish(seeded(), 'a', 'bagels', 10, 'w1');
    expect(get(r, 'w1')).toMatchObject({ state: 'wish', wishedBy: 'a' });
    r = addChip(r, chip('bg', 'Bagels', 500), 20);
    expect(get(r, 'w1')).toBeUndefined();
    expect(get(r, 'bg').claimers).toEqual(['a']);
    expect(get(r, 'bg').state).toBe('claimed');
  });
  it('leaves the wisher out and in overCap when the price breaks the cap', () => {
    let r = wish(seeded(), 'a', 'bagels', 10, 'w1');
    r = addChip(r, chip('bg', 'Bagels', 5000), 20);
    expect(get(r, 'bg').claimers).toEqual([]);
    expect(get(r, 'bg').overCap).toEqual(['a']);
    expect(get(r, 'bg').state).toBe('open');
  });
  it('a shopper wish has wishedBy null and resolves to a shopper claim', () => {
    let r = wish(seeded(), 's', 'bagels', 10, 'w1');
    expect(get(r, 'w1').wishedBy).toBeNull();
    r = addChip(r, chip('bg', 'bagels', 5000), 20);
    expect(get(r, 'bg').claimers).toEqual(['s']);
  });
  it('generates an id when none is supplied', () => {
    const r = wish(seeded(), 'a', 'bagels', 10);
    expect(r.chips.at(-1)!.id).toMatch(/^[0-9a-f-]{36}$/);
  });
});

describe('setChipPrice / fixChip', () => {
  it('flags a claimer whose room breaks, and clears it when the price falls', () => {
    let r = ok(claim(seeded(), 'eggs', 'a', 1));
    r = ok(claim(r, 'towels', 'a', 2));
    r = addChip(r, chip('tbd', 'Mystery cheese', null), 3);
    r = ok(claim(r, 'tbd', 'a', 4));
    r = setChipPrice(r, 'tbd', 2000, 'web');
    expect(get(r, 'tbd')).toMatchObject({ priceCents: 2000, priceSource: 'web', overCap: ['a'] });
    r = setChipPrice(r, 'tbd', 500, 'web');
    expect(get(r, 'tbd').overCap).toEqual([]);
  });
  it('naming an identifying chip makes it open', () => {
    let r = addChip(seeded(), chip('m', '', null), 400);
    r = fixChip(r, 'm', 'Butter', 599, 500);
    expect(get(r, 'm')).toMatchObject({ state: 'open', name: 'Butter', priceCents: 599 });
  });
  it('fixChip with a price calls setChipPrice', () => {
    let r = ok(claim(seeded(), 'milk', 'a', 1));
    r = fixChip(r, 'milk', undefined, 450, 10);
    expect(get(r, 'milk').priceCents).toBe(450);
    expect(sharesFor(r).get('a')).toBe(450);
  });
  it('refuses once the run is past locked (receipt and later)', () => {
    for (const state of ['receipt', 'settled', 'partlySettled'] as const) {
      const r = { ...ok(claim(seeded(), 'milk', 'a', 1)), state };
      expect(fixChip(r, 'milk', 'Butter', 450, 10)).toBe(r);
      expect(setChipPrice(r, 'milk', 450, 'sticker')).toBe(r);
    }
    const locked = lock(checkout(seeded(), 1000, 50), 1050);
    expect(get(fixChip(locked, 'milk', undefined, 450, 1100), 'milk').priceCents).toBe(450);
  });
  it('a named identifying chip resolves a wish', () => {
    let r = wish(seeded(), 'a', 'butter', 1, 'w1');
    r = addChip(r, chip('m', '', null), 2);
    r = fixChip(r, 'm', 'Butter', 599, 3);
    expect(get(r, 'm').claimers).toEqual(['a']);
    expect(get(r, 'w1')).toBeUndefined();
  });
});

describe('checkout / lock / backToCart / putBack', () => {
  it('lock before lastCallEndsAt is a no-op', () => {
    const r = checkout(seeded(), 1000, 50);
    expect(r.state).toBe('lastCall');
    expect(r.lastCallEndsAt).toBe(1050);
    expect(lock(r, 1049)).toBe(r);
  });
  it('lock from open is a no-op', () => {
    const r = seeded();
    expect(lock(r, 99999)).toBe(r);
  });
  it('lock drops identifying chips and locks the rest', () => {
    let r = addChip(seeded(), chip('m', '', null), 400);
    r = ok(claim(r, 'eggs', 'a', 401));
    r = lock(checkout(r, 1000, 50), 1050);
    expect(r.state).toBe('locked');
    expect(get(r, 'm')).toMatchObject({ dropped: true, state: 'identifying' });
    expect(get(r, 'eggs').state).toBe('locked');
    expect(get(r, 'milk').state).toBe('locked');
  });
  it('putBack only works when locked; sharesFor excludes it; backToCart clears it', () => {
    let r = ok(claim(seeded(), 'eggs', 'a', 1));
    const open = checkout(r, 1000, 50);
    expect(putBack(open, 'eggs')).toBe(open);
    r = putBack(lock(open, 1050), 'eggs');
    expect(get(r, 'eggs').putBack).toBe(true);
    expect(sharesFor(r).get('a')).toBe(0);
    expect(roomsFor(r).get('a')).toBe(4000);
    r = backToCart(r);
    expect(r.state).toBe('open');
    expect(r.lastCallEndsAt).toBeNull();
    expect(get(r, 'eggs')).toMatchObject({ putBack: false, state: 'claimed' });
    expect(get(r, 'milk').state).toBe('open');
    expect(sharesFor(r).get('a')).toBe(872);
  });
  it('backToCart works from lastCall and ignores an open run', () => {
    const lc = checkout(seeded(), 1, 50);
    expect(backToCart(lc).state).toBe('open');
    const r = seeded();
    expect(backToCart(r)).toBe(r);
  });
});

describe('unclaimed', () => {
  it('returns chips with no claimers, excluding wishes and removed', () => {
    let r = seeded();
    for (const id of ['eggs', 'towels', 'towels2']) r = ok(claim(r, id, 's', 1));
    r = wish(r, 'a', 'bagels', 2, 'w1');
    expect(unclaimed(r).map((c) => c.id)).toEqual(['milk']);
    r = removeChip(r, 'milk', 3);
    expect(unclaimed(r)).toEqual([]);
  });
});

describe('fix round 1', () => {
  it('leave keeps a removed chip removed and undo restores remaining claims', () => {
    let r = ok(claim(seeded(), 'eggs', 'a', 1));
    r = ok(claim(r, 'eggs', 'b', 2));
    r = removeChip(r, 'eggs', 1000);
    r = ok(leave(r, 'eggs', 'a'));
    expect(get(r, 'eggs')).toMatchObject({ state: 'removed', claimers: ['b'], removedAt: 1000 });
    r = ok(leave(r, 'eggs', 'b'));
    expect(get(r, 'eggs').state).toBe('removed');
    r = ok(undoRemove(r, 'eggs', 2000));
    expect(get(r, 'eggs').state).toBe('open');
  });
  it('late identification after lock leaves a dropped chip unchanged', () => {
    let r = addChip(seeded(), chip('m', '', null), 400);
    r = lock(checkout(r, 1000, 50), 1050);
    expect(setChipLive(r, 'm', 'Butter', 599, 'web', 1100)).toBe(r);
    expect(fixChip(r, 'm', 'Butter', 599, 1100)).toBe(r);
  });
});

describe('quantity', () => {
  const apples = (q = 2, price: number | null = 110) => addChip(seeded(), { ...chip('apple', 'Cosmic Crisp Apple', price), quantity: q }, 400);

  it('shares split the line total (unit price times quantity), leftover cents to the earliest claimers', () => {
    let r = ok(claim(apples(), 'apple', 'a', 1));
    expect(sharesFor(r).get('a')).toBe(220);
    r = ok(claim(r, 'apple', 'b', 2));
    r = ok(claim(r, 'apple', 's', 3));
    expect([sharesFor(r).get('a'), sharesFor(r).get('b'), sharesFor(r).get('s')]).toEqual([74, 73, 73]);
  });
  it('room counts the full line total', () => {
    const r = ok(claim(apples(3), 'apple', 'a', 1));
    expect(roomsFor(r).get('a')).toBe(4000 - 330);
  });
  it('the cap check uses the line total, not the unit price', () => {
    let r = addChip(seeded(), { ...chip('wine', 'Red Wine', 1500), quantity: 3 }, 400);
    expect(claim(r, 'wine', 'a', 1)).toEqual({ error: 'over cap' }); // 4500 > 4000
    r = ok(setQuantity(r, 'wine', 2));
    expect(get(ok(claim(r, 'wine', 'a', 2)), 'wine').claimers).toEqual(['a']);
  });

  it('setQuantity sets the count and re-checks every claimer like a price change', () => {
    let r = ok(claim(seeded(), 'towels', 'a', 1)); // 2399 of a's 4000
    r = ok(setQuantity(r, 'towels', 2)); // 4798 > 4000
    expect(get(r, 'towels')).toMatchObject({ quantity: 2, overCap: ['a'], claimers: ['a'] });
    expect(sharesFor(r).get('a')).toBe(4798);
    r = ok(setQuantity(r, 'towels', 1));
    expect(get(r, 'towels')).toMatchObject({ quantity: 1, overCap: [] });
  });
  it('setQuantity works in last call and refuses once locked', () => {
    expect(get(ok(setQuantity(checkout(seeded(), 10, 50), 'milk', 3)), 'milk').quantity).toBe(3);
    const locked = lock(checkout(seeded(), 10, 50), 60);
    expect(setQuantity(locked, 'milk', 3)).toEqual({ error: 'cart closed' });
  });
  it('setQuantity refuses bad counts, unknown chips, wishes and removed chips', () => {
    for (const q of [0, 21, 1.5, -1, Number.NaN]) expect(setQuantity(seeded(), 'milk', q)).toEqual({ error: 'invalid quantity' });
    expect(setQuantity(seeded(), 'nope', 2)).toEqual({ error: 'unknown chip' });
    expect(setQuantity(wish(seeded(), 'a', 'bagels', 1, 'w1'), 'w1', 2)).toEqual({ error: 'not adjustable' });
    expect(setQuantity(removeChip(seeded(), 'milk', 1), 'milk', 2)).toEqual({ error: 'not adjustable' });
  });
  it('setQuantity to the same count is a no-op', () => {
    const r = seeded();
    expect(setQuantity(r, 'milk', 1)).toBe(r);
  });

  it('countAgain adds one when the item is seen again outside the window, and not inside it', () => {
    let r = apples(1); // added at 400
    r = countAgain(r, 'apple', 2000, 3000); // 1.6 s after: the same detection
    expect(get(r, 'apple').quantity).toBe(1);
    r = countAgain(r, 'apple', 9000, 3000);
    expect(get(r, 'apple')).toMatchObject({ quantity: 2, lastSeenAt: 9000 });
    r = countAgain(r, 'apple', 10_000, 3000); // 1 s after the last count
    expect(get(r, 'apple').quantity).toBe(2);
    r = countAgain(r, 'apple', 20_000, 3000);
    expect(get(r, 'apple').quantity).toBe(3);
  });
  it('countAgain stops at 20 and flags a claimer the new count puts over cap', () => {
    let r = ok(claim(seeded(), 'towels', 'a', 1));
    r = countAgain(r, 'towels', 10_000, 3000);
    expect(get(r, 'towels')).toMatchObject({ quantity: 2, overCap: ['a'] });
    r = ok(setQuantity(r, 'towels', 20));
    r = countAgain(r, 'towels', 30_000, 3000);
    expect(get(r, 'towels').quantity).toBe(20);
  });
  it('countAgain leaves a locked run alone', () => {
    const r = lock(checkout(apples(1), 1000, 50), 1050);
    expect(countAgain(r, 'apple', 9000, 3000)).toBe(r);
  });

  it('liveSameName finds a live chip by normalized name at any age, never a wish, removed or identifying chip', () => {
    let r = apples(1);
    expect(liveSameName(r, '  cosmic CRISP apple! ', 'x')?.id).toBe('apple');
    expect(liveSameName(r, 'Cosmic Crisp Apple', 'apple')).toBeUndefined();
    r = removeChip(r, 'apple', 500);
    expect(liveSameName(r, 'Cosmic Crisp Apple', 'x')).toBeUndefined();
    r = wish(seeded(), 'a', 'Bagels', 1, 'w1');
    expect(liveSameName(r, 'bagels', 'x')).toBeUndefined();
    expect(liveSameName(seeded(), '', 'x')).toBeUndefined();
  });

  it('with MERGE_DUPLICATES=1 a same-name chip is never flagged as a duplicate', () => {
    process.env.MERGE_DUPLICATES = '1';
    try {
      let r = addChip(seeded(), chip('milk2', 'Milk', 429), 400);
      expect(get(r, 'milk2').duplicateOf).toBeNull();
      r = addChip(r, chip('m', '', null), 500);
      r = setChipLive(r, 'm', 'Milk', 429, 'sticker', 600);
      expect(get(r, 'm').duplicateOf).toBeNull();
    } finally {
      delete process.env.MERGE_DUPLICATES;
    }
  });
});
