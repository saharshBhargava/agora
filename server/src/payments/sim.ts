// Realistic in-memory payments simulator (Cybersource-shaped behavior).
import type { AuthResult, PaymentsProvider, PayoutRecord, TestCard } from './provider.js';

const APPROVAL = '888888';
const MAX_AUTH_CENTS = 100000;
const DECLINE_CARD = '42423482938483873';
const OUTAGE_CARD = '4000000000000002';

type AuthState = { authorized: number; reversed: number; captured: number };
export type CallRecord = { method: string; ref: string; args: unknown[] };

export class SimPayments implements PaymentsProvider {
  private readonly auths = new Map<string, AuthState>();
  private readonly log: CallRecord[] = [];
  private counter = 0;

  get calls(): readonly CallRecord[] {
    return this.log;
  }

  private nextId(prefix: string): string {
    this.counter += 1;
    return `${prefix}${String(this.counter).padStart(22 - prefix.length, '0')}`;
  }

  async authorize(ref: string, card: TestCard, amountCents: number): Promise<AuthResult> {
    this.log.push({ method: 'authorize', ref, args: [card, amountCents] });
    if (card.number === OUTAGE_CARD) throw new Error('simulated outage');
    const authId = this.nextId('68');
    if (card.expYear === 1998 || card.number === DECLINE_CARD || amountCents > MAX_AUTH_CENTS) {
      return { status: 'DECLINED', authId, approvalCode: '', authorizedCents: 0 };
    }
    this.auths.set(authId, { authorized: amountCents, reversed: 0, captured: 0 });
    return { status: 'AUTHORIZED', authId, approvalCode: APPROVAL, authorizedCents: amountCents };
  }

  async incremental(ref: string, authId: string, deltaCents: number): Promise<AuthResult> {
    this.log.push({ method: 'incremental', ref, args: [authId, deltaCents] });
    const a = this.auths.get(authId);
    if (!a) return { status: 'DECLINED', authId, approvalCode: '', authorizedCents: 0 };
    if (a.authorized + deltaCents > MAX_AUTH_CENTS) {
      return { status: 'DECLINED', authId, approvalCode: '', authorizedCents: a.authorized };
    }
    a.authorized += deltaCents;
    return { status: 'AUTHORIZED', authId, approvalCode: APPROVAL, authorizedCents: a.authorized };
  }

  async reverse(ref: string, authId: string, amountCents: number): Promise<{ status: 'REVERSED'; reversedCents: number }> {
    this.log.push({ method: 'reverse', ref, args: [authId, amountCents] });
    const a = this.auths.get(authId);
    if (!a) throw new Error('unknown authorization');
    if (amountCents > a.authorized - a.reversed - a.captured) throw new Error('reverse exceeds authorized');
    a.reversed += amountCents;
    return { status: 'REVERSED', reversedCents: amountCents };
  }

  async capture(ref: string, authId: string, amountCents: number): Promise<{ status: 'PENDING'; captureId: string }> {
    this.log.push({ method: 'capture', ref, args: [authId, amountCents] });
    const a = this.auths.get(authId);
    if (!a) throw new Error('unknown authorization');
    if (amountCents > a.authorized - a.reversed - a.captured) throw new Error('capture exceeds authorized');
    a.captured += amountCents;
    return { status: 'PENDING', captureId: this.nextId('77') };
  }

  async payout(ref: string, recipientPan: string, amountCents: number): Promise<PayoutRecord> {
    this.log.push({ method: 'payout', ref, args: [recipientPan, amountCents] });
    return { simulated: true, businessApplicationId: 'FD', amountCents, recipientPan, requestId: this.nextId('99') };
  }
}
