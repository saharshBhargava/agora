'use client';
import type { Person, Run } from '@/lib/types';
import { formatCents } from '@/lib/money';
import { Avatar } from './Avatar';

/** One card per claimer. Retry is a button for the shopper only. The shopper's payout is the hero above. */
export function SettleLines({ run, me, canRetry, onRetry, busy }: { run: Run; me: string; canRetry: boolean; onRetry: () => void; busy: boolean }) {
  const claimers = run.people.filter((p) => !p.isShopper);
  return (
    <ul className="settle-lines" aria-label="Settle results">
      {claimers.map((p) => {
        const s = run.settle[p.id];
        if (!s) return null;
        let sub: React.ReactNode;
        let amount: number | null = null;
        let auth: string | null = null;
        if (s.step === 'captured') {
          amount = s.capturedCents;
          auth = s.approvalCode;
          sub = s.owedCents > 0
            ? `Captured ${formatCents(s.capturedCents)} · ${formatCents(s.owedCents)} owed`
            : `${formatCents(s.releasedCents)} released · settles tonight`;
        } else if (s.step === 'reversed' && s.shareCents === 0) {
          amount = 0;
          sub = `Nothing captured · ${formatCents(s.releasedCents)} released`;
        } else if (s.step === 'failed') {
          sub = canRetry ? "Didn't go through" : "Didn't go through, the shopper will retry";
        } else {
          sub = 'Settling…';
        }
        return (
          <li key={p.id} className="card person-card">
            <Avatar person={p as Person} people={run.people} me={me} size="lg" />
            <div className="person-main">
              <span className="person-name">{p.name}</span>
              <span className="person-sub">{sub}</span>
            </div>
            <div className="person-side">
              {amount !== null && (
                <span className="money person-amount"><span className="sr-only">Captured </span>{formatCents(amount)}</span>
              )}
              {auth && <span className="mono person-auth">auth {auth}</span>}
              {s.step === 'failed' && canRetry && (
                <button type="button" className="btn btn-sm" disabled={busy} onClick={onRetry}>Retry</button>
              )}
            </div>
          </li>
        );
      })}
    </ul>
  );
}
