// Realistic payments simulator (Cybersource-shaped behavior). With a data dir its authorizations
// survive a restart in `<dataDir>/sim-payments.json`.
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { AuthResult, PaymentsProvider, PayoutRecord, TestCard } from './provider.js';

const APPROVAL = '888888';
const MAX_AUTH_CENTS = 100000;
const DECLINE_CARD = '42423482938483873';
const OUTAGE_CARD = '4000000000000002';
/** Stripe-style "attaches fine, charges fail": authorize succeeds, every capture and incremental throws. */
export const FAIL_CAPTURE_CARD = '4000000000000341';
const CAPTURE_FAILURE = 'simulated capture failure';

/** `preAuth` marks a pre-authorization (Cybersource authIndicator "0"), which every join is. */
type AuthState = { authorized: number; reversed: number; captured: number; preAuth: boolean; failCapture?: true };
export type CallRecord = { method: string; ref: string; args: unknown[] };

export class SimPayments implements PaymentsProvider {
  private readonly auths = new Map<string, AuthState>();
  private readonly log: CallRecord[] = [];
  private readonly file: string | null;
  /** Time-based so ids issued after a restart never collide with earlier ones. */
  private readonly epoch = String(Date.now()).slice(-13).padStart(13, '0');
  private counter = 0;

  constructor(dataDir?: string) {
    this.file = dataDir ? join(dataDir, 'sim-payments.json') : null;
    if (this.file && existsSync(this.file)) {
      try {
        const saved = JSON.parse(readFileSync(this.file, 'utf8')) as { auths?: Record<string, AuthState> };
        for (const [id, a] of Object.entries(saved.auths ?? {})) this.auths.set(id, { ...a, preAuth: a.preAuth ?? true });
      } catch {
        // A corrupt file starts empty rather than blocking the server.
      }
    }
  }

  get calls(): readonly CallRecord[] {
    return this.log;
  }

  /** 22 digits: 2-digit prefix, 13-digit start time, 7-digit counter. */
  private nextId(prefix: string): string {
    this.counter += 1;
    return `${prefix}${this.epoch}${String(this.counter).padStart(22 - prefix.length - this.epoch.length, '0')}`;
  }

  private persist(): void {
    if (!this.file) return;
    try {
      mkdirSync(join(this.file, '..'), { recursive: true });
      const tmp = `${this.file}.tmp`;
      writeFileSync(tmp, JSON.stringify({ auths: Object.fromEntries(this.auths) }));
      renameSync(tmp, this.file);
    } catch (e) {
      console.error('sim payments snapshot failed', e);
    }
  }

  async authorize(ref: string, card: TestCard, amountCents: number): Promise<AuthResult> {
    this.log.push({ method: 'authorize', ref, args: [card, amountCents] });
    if (card.number === OUTAGE_CARD) throw new Error('simulated outage');
    const authId = this.nextId('68');
    if (card.expYear === 1998 || card.number === DECLINE_CARD || amountCents > MAX_AUTH_CENTS) {
      return { status: 'DECLINED', authId, approvalCode: '', authorizedCents: 0 };
    }
    this.auths.set(authId, {
      authorized: amountCents, reversed: 0, captured: 0, preAuth: true,
      ...(card.number === FAIL_CAPTURE_CARD ? { failCapture: true as const } : {}),
    });
    this.persist();
    return { status: 'AUTHORIZED', authId, approvalCode: APPROVAL, authorizedCents: amountCents };
  }

  async incremental(ref: string, authId: string, deltaCents: number): Promise<AuthResult> {
    this.log.push({ method: 'incremental', ref, args: [authId, deltaCents] });
    const a = this.auths.get(authId);
    if (!a) return { status: 'DECLINED', authId, approvalCode: '', authorizedCents: 0 };
    if (a.failCapture) throw new Error(CAPTURE_FAILURE);
    if (a.authorized + deltaCents > MAX_AUTH_CENTS) {
      return { status: 'DECLINED', authId, approvalCode: '', authorizedCents: a.authorized };
    }
    a.authorized += deltaCents;
    this.persist();
    return { status: 'AUTHORIZED', authId, approvalCode: APPROVAL, authorizedCents: a.authorized };
  }

  async reverse(ref: string, authId: string, amountCents: number): Promise<{ status: 'REVERSED'; reversedCents: number }> {
    this.log.push({ method: 'reverse', ref, args: [authId, amountCents] });
    const a = this.auths.get(authId);
    if (!a) throw new Error('unknown authorization');
    if (amountCents > a.authorized - a.reversed - a.captured) throw new Error('reverse exceeds authorized');
    a.reversed += amountCents;
    this.persist();
    return { status: 'REVERSED', reversedCents: amountCents };
  }

  async capture(ref: string, authId: string, amountCents: number): Promise<{ status: 'PENDING'; captureId: string }> {
    this.log.push({ method: 'capture', ref, args: [authId, amountCents] });
    const a = this.auths.get(authId);
    if (!a) throw new Error('unknown authorization');
    if (a.failCapture) throw new Error(CAPTURE_FAILURE);
    if (amountCents > a.authorized - a.reversed - a.captured) throw new Error('capture exceeds authorized');
    a.captured += amountCents;
    this.persist();
    return { status: 'PENDING', captureId: this.nextId('77') };
  }

  async payout(ref: string, recipientPan: string, amountCents: number): Promise<PayoutRecord> {
    this.log.push({ method: 'payout', ref, args: [recipientPan, amountCents] });
    return { simulated: true, businessApplicationId: 'FD', amountCents, recipientPan, requestId: this.nextId('99') };
  }
}

/** `SIM_FAIL_CAPTURE`: a comma list of person names, matched case-insensitively. */
export function simFailNames(env: string | undefined): Set<string> {
  return new Set((env ?? '').split(',').map((n) => n.trim().toLowerCase()).filter(Boolean));
}

/** Wraps a provider so capture and incremental throw for the given authorizations (demo of partly settled). */
export function failingCaptures(p: PaymentsProvider, authIds: ReadonlySet<string>): PaymentsProvider {
  return {
    authorize: (ref, card, amount) => p.authorize(ref, card, amount),
    incremental: async (ref, authId, delta) => {
      if (authIds.has(authId)) throw new Error(CAPTURE_FAILURE);
      return p.incremental(ref, authId, delta);
    },
    reverse: (ref, authId, amount) => p.reverse(ref, authId, amount),
    capture: async (ref, authId, amount) => {
      if (authIds.has(authId)) throw new Error(CAPTURE_FAILURE);
      return p.capture(ref, authId, amount);
    },
    payout: (ref, pan, amount) => p.payout(ref, pan, amount),
  };
}
