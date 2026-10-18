import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { SimPayments } from '../src/payments/sim.js';
import { getPayments } from '../src/payments/provider.js';

const card = { number: '4111111111111111', expMonth: 12, expYear: 2031 };

describe('SimPayments', () => {
  it('authorizes with approval code and 22-digit authId', async () => {
    const p = new SimPayments();
    const r = await p.authorize('r1', card, 4000);
    expect(r.status).toBe('AUTHORIZED');
    expect(r.approvalCode).toBe('888888');
    expect(r.authId).toMatch(/^\d{22}$/);
    expect(r.authorizedCents).toBe(4000);
  });

  it('declines expYear 1998 and the decline card', async () => {
    const p = new SimPayments();
    expect((await p.authorize('r', { ...card, expYear: 1998 }, 4000)).status).toBe('DECLINED');
    expect((await p.authorize('r', { ...card, number: '42423482938483873' }, 4000)).status).toBe('DECLINED');
  });

  it('rejects with simulated outage', async () => {
    await expect(new SimPayments().authorize('r', { ...card, number: '4000000000000002' }, 100)).rejects.toThrow('simulated outage');
  });

  it('incremental adds, and declines past 100000 or unknown id', async () => {
    const p = new SimPayments();
    const a = await p.authorize('r', card, 4000);
    expect((await p.incremental('r', a.authId, 500)).authorizedCents).toBe(4500);
    expect((await p.incremental('r', a.authId, 95501)).status).toBe('DECLINED');
    expect((await p.incremental('r', 'nope', 5)).status).toBe('DECLINED');
  });

  it('reverse then capture', async () => {
    const p = new SimPayments();
    const a = await p.authorize('r', card, 4000);
    expect(await p.reverse('r', a.authId, 3564)).toEqual({ status: 'REVERSED', reversedCents: 3564 });
    const c = await p.capture('r', a.authId, 436);
    expect(c.status).toBe('PENDING');
    expect(c.captureId).toBeTruthy();
    await expect(p.capture('r', a.authId, 1)).rejects.toThrow('capture exceeds authorized');
    await expect(p.reverse('r', a.authId, 1)).rejects.toThrow();
  });

  it('capture over authorized throws', async () => {
    const p = new SimPayments();
    const a = await p.authorize('r', card, 4000);
    await expect(p.capture('r', a.authId, 4001)).rejects.toThrow('capture exceeds authorized');
  });

  it('payout is simulated FD', async () => {
    const r = await new SimPayments().payout('r', '4111111111111111', 3271);
    expect(r).toMatchObject({ simulated: true, businessApplicationId: 'FD', amountCents: 3271, recipientPan: '4111111111111111' });
    expect(r.requestId).toBeTruthy();
  });

  it('logs calls in order', async () => {
    const p = new SimPayments();
    const a = await p.authorize('r1', card, 4000);
    await p.reverse('r2', a.authId, 10);
    expect(p.calls.map((c) => [c.method, c.ref])).toEqual([['authorize', 'r1'], ['reverse', 'r2']]);
  });

  it('persists auths so a reloaded simulator can reverse and capture them', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'dibs-sim-'));
    const before = new SimPayments(dir);
    const a = await before.authorize('r', card, 4000);
    const b = await before.authorize('r', card, 4000);
    await before.incremental('r', b.authId, 500);
    expect(existsSync(join(dir, 'sim-payments.json'))).toBe(true);
    const stored = JSON.parse(readFileSync(join(dir, 'sim-payments.json'), 'utf8'));
    expect(stored.auths[a.authId]).toEqual({ authorized: 4000, reversed: 0, captured: 0, preAuth: true });

    const after = new SimPayments(dir);
    expect(await after.reverse('r', a.authId, 3564)).toEqual({ status: 'REVERSED', reversedCents: 3564 });
    expect((await after.capture('r', a.authId, 436)).status).toBe('PENDING');
    expect((await after.capture('r', b.authId, 4500)).status).toBe('PENDING');
    // Captured amounts survive another reload.
    await expect(new SimPayments(dir).capture('r', a.authId, 1)).rejects.toThrow('capture exceeds authorized');
    // New ids never collide with ids issued before the restart.
    const c = await after.authorize('r', card, 100);
    expect(c.authId).toMatch(/^\d{22}$/);
    expect([a.authId, b.authId]).not.toContain(c.authId);
  });

  it('ids from two fresh simulators do not collide', async () => {
    const x = await new SimPayments().authorize('r', card, 100);
    await new Promise((r) => setTimeout(r, 5));
    const y = await new SimPayments().authorize('r', card, 100);
    expect(x.authId).not.toBe(y.authId);
    expect(y.authId).toMatch(/^\d{22}$/);
  });

  it('getPayments defaults to sim', () => {
    const prev = process.env.PAYMENTS;
    delete process.env.PAYMENTS;
    try {
      expect(getPayments()).toBeInstanceOf(SimPayments);
    } finally {
      if (prev !== undefined) process.env.PAYMENTS = prev;
    }
  });
});
