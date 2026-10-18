'use client';
import type { Run } from '@/lib/types';
import { formatCents } from '@/lib/money';

/** One line per claimer, plus the shopper's reimbursement. Retry is a button for the shopper only. */
export function SettleLines({ run, canRetry, onRetry, busy }: { run: Run; canRetry: boolean; onRetry: () => void; busy: boolean }) {
  const claimers = run.people.filter((p) => !p.isShopper);
  return (
    <ul className="settle-lines" aria-label="Settle results">
      {claimers.map((p) => {
        const s = run.settle[p.id];
        if (!s) return null;
        let line: React.ReactNode = null;
        if (s.step === 'captured') {
          line = s.owedCents > 0
            ? `Captured ${formatCents(s.capturedCents)} · ${formatCents(s.owedCents)} owed`
            : `Captured ${formatCents(s.capturedCents)} (settles tonight) · ${formatCents(s.releasedCents)} released${s.approvalCode ? ` · approval ${s.approvalCode}` : ''}`;
        } else if (s.step === 'reversed' && s.shareCents === 0) {
          line = `Nothing captured · ${formatCents(s.releasedCents)} released`;
        } else if (s.step === 'failed') {
          line = canRetry ? (
            <button type="button" className="btn" disabled={busy} onClick={onRetry}>Retry</button>
          ) : (
            <span className="muted">Didn't go through, the shopper will retry</span>
          );
        } else {
          line = <span className="muted">Settling…</span>;
        }
        return (
          <li key={p.id} className="card settle-line">
            <span className="settle-name">{p.name}</span>
            {typeof line === 'string' ? <span>{line}</span> : line}
          </li>
        );
      })}
      {run.payout && (
        <li className="card settle-line">
          <span className="settle-name">{run.people.find((p) => p.isShopper)?.name ?? 'Shopper'}</span>
          <span>{`Reimbursed ${formatCents(run.payout.amountCents)} (simulated Visa Direct)`}</span>
        </li>
      )}
    </ul>
  );
}
