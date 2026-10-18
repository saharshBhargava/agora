// Payments provider interface. One authorization per claimer at join; at settle
// reverse the unused part and capture each person's exact share.
import type { PayoutRecord } from '../types.js';
import { SimPayments } from './sim.js';

export type { PayoutRecord };

export type TestCard = { number: string; expMonth: number; expYear: number };

export type AuthResult = {
  status: 'AUTHORIZED' | 'DECLINED';
  authId: string;
  approvalCode: string;
  authorizedCents: number;
};

export interface PaymentsProvider {
  authorize(ref: string, card: TestCard, amountCents: number): Promise<AuthResult>;
  incremental(ref: string, authId: string, deltaCents: number): Promise<AuthResult>;
  reverse(ref: string, authId: string, amountCents: number): Promise<{ status: 'REVERSED'; reversedCents: number }>;
  capture(ref: string, authId: string, amountCents: number): Promise<{ status: 'PENDING'; captureId: string }>;
  payout(ref: string, recipientPan: string, amountCents: number): Promise<PayoutRecord>;
}

/** `dataDir` lets the simulator keep its authorizations across a restart. */
export function getPayments(dataDir?: string): PaymentsProvider {
  const mode = process.env.PAYMENTS ?? 'sim';
  if (mode === 'sim') return new SimPayments(dataDir);
  throw new Error(`PAYMENTS=${mode} is not wired yet`);
}
