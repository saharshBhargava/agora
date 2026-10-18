'use client';
import { useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { api } from '@/lib/api';
import { useRun } from '@/lib/socket';
import { endedMessage } from '@/lib/ended';
import { formatCents, wholeCents } from '@/lib/money';
import { coverage, isLiveChip, lineCents, listNames, nameWithQty } from '@/lib/share';
import { ReceiptCamera } from '@/components/ReceiptCamera';
import { ReceiptMatch, receiptCounts } from '@/components/ReceiptMatch';
import { SettleLines } from '@/components/SettleLines';
import type { Run } from '@/lib/types';

/** "Milk, $4.29, stays with Jake." / "Milk ($4.29) and Gum ($1.99) stay with Jake." / null when nothing does. */
export function staysWith(run: Run, shopperName: string): string | null {
  const items: { name: string; cents: number | null }[] = run.chips
    .filter((c) => isLiveChip(c) && c.claimers.length === 0)
    .map((c) => ({ name: nameWithQty(c), cents: lineCents(c) }));
  for (const i of run.receipt?.mine ?? []) {
    const line = run.receipt?.lines[i];
    if (line) items.push({ name: line.text, cents: line.cents });
  }
  if (items.length === 0) return null;
  const money = (c: number | null) => (c === null ? '~$?' : formatCents(c));
  if (items.length === 1) return `${items[0].name}, ${money(items[0].cents)}, stays with ${shopperName}.`;
  return `${listNames(items.map((i) => `${i.name} (${money(i.cents)})`))} stay with ${shopperName}.`;
}

export default function SettleScreen() {
  const params = useSearchParams();
  const runId = params.get('run') ?? '';
  const personId = params.get('person') ?? '';
  const mock = params.get('mock') === '1';
  const { run, connected, ended, endedReason } = useRun(runId || null, personId || null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!runId || !personId) return <p className="error" role="alert">This link is missing its run.</p>;
  if (ended) return <p className="muted" role="status">{endedMessage(endedReason)}</p>;
  if (!run) return <p className="muted" role="status">{connected ? 'Loading the run' : 'Connecting'}</p>;

  const isShopper = personId === run.shopperId;
  const act = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Something went wrong');
    } finally {
      setBusy(false);
    }
  };
  const confirm = () => act(() => api.confirm(runId, personId));
  const mockHref = `/settle?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}&mock=1`;
  const back = `/${isShopper ? 'shopper' : 'claim'}?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}`;
  const hasResults = Object.keys(run.settle).length > 0 || run.payout !== null;
  const canConfirm = isShopper && (run.state === 'receipt' || run.state === 'partlySettled');
  const shopperName = run.people.find((p) => p.id === run.shopperId)?.name ?? 'The shopper';
  const stays = staysWith(run, shopperName);
  const settled = run.state === 'settled' || run.state === 'partlySettled';
  const settles = Object.values(run.settle);
  const failed = settles.filter((x) => x.step === 'failed').length;
  const soFar = run.payout?.amountCents ?? settles.reduce((t, x) => t + (x.step === 'captured' ? x.capturedCents : 0), 0);
  const counts = run.receipt ? receiptCounts(run.receipt) : { matched: 0, items: 0, needs: 0 };
  const matchedIds = new Set(run.receipt?.matches.map((m) => m.chipId) ?? []);
  const preview = coverage(run.people, run.chips.filter((c) => matchedIds.has(c.id)));

  if (run.state === 'locked' && isShopper) {
    return (
      <ReceiptCamera
        busy={busy}
        mock={mock}
        mockHref={mockHref}
        error={error}
        onError={setError}
        onSubmit={(imageBase64) => void act(() => api.receipt(runId, personId, imageBase64))}
      />
    );
  }

  return (
    <div className="settle bleed">
      {run.state === 'partlySettled' ? (
        <section className="settle-hero settle-hero-partly" aria-label="Run partly settled">
          <span className="partly-pill">Partly settled</span>
          <h1 className="settle-hero-who">{shopperName} gets back so far</h1>
          <span className="money settle-hero-amount">{wholeCents(soFar)}</span>
          <p className="settle-hero-note">
            {failed === 1 ? "One share didn't go through." : `${failed} shares didn't go through.`} Retrying never repeats what already worked.
          </p>
        </section>
      ) : run.payout ? (
        <section className="settle-hero" aria-label="Run settled">
          <span className="settle-hero-tag">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" strokeWidth="2" aria-hidden="true"><path d="M5 12l5 5 9-10" /></svg>
            <span>Run settled · nobody chases anybody</span>
          </span>
          <h1 className="settle-hero-who">{shopperName} gets back</h1>
          <span className="money settle-hero-amount">{formatCents(run.payout.amountCents)}</span>
          <p className="settle-hero-note">
            {`Pushed to ${shopperName}'s card over Visa Direct (simulated in this build).`}{stays ? ` ${stays}` : ''}
          </p>
        </section>
      ) : run.state === 'receipt' && run.receipt ? (
        <header className="settle-head">
          <h1>Check the receipt</h1>
          <p className="muted">
            {`${counts.matched} ${counts.matched === 1 ? 'line' : 'lines'} matched`}{counts.needs ? ` · ${counts.needs} ${counts.needs === 1 ? 'needs' : 'need'} you` : ''}
          </p>
        </header>
      ) : (
        <header className="settle-head">
          <span className="wordmark" aria-hidden="true">dibs</span>
          <h1>Settle</h1>
        </header>
      )}

      <div className="settle-body">
        {!connected && <p className="muted" role="status">Reconnecting…</p>}

        {(run.state === 'open' || run.state === 'lastCall') && (
          <p className="muted">The run is still open. <a href={back}>Back to the cart</a></p>
        )}

        {run.state === 'locked' && <p className="muted" role="status">Waiting for the shopper to read the receipt.</p>}

        {hasResults && <SettleLines run={run} me={personId} shopperName={shopperName} canRetry={isShopper} busy={busy} onRetry={confirm} />}

        {run.receipt && (
          <ReceiptMatch
            receipt={run.receipt}
            chips={run.chips}
            canFix={isShopper && run.state === 'receipt'}
            people={run.people}
            compact={settled}
            busy={busy}
            onFix={(i, target) => void act(() => api.fixReceiptLine(runId, personId, i, target))}
          />
        )}

        {run.state === 'receipt' && preview.segments.length > 0 && (
          <div className="check-total">
            <span>Captured from {listNames(preview.segments.map((g) => g.name))}</span>
            <strong>{formatCents(preview.coveredCents)}</strong>
          </div>
        )}
        {canConfirm && run.state === 'receipt' && (
          <button type="button" className="btn" disabled={busy} onClick={confirm}>Confirm & charge</button>
        )}
        {!isShopper && run.state === 'receipt' && <p className="muted" role="status">Waiting for the shopper to confirm.</p>}
        {error && <p className="error" role="alert">{error}</p>}

        {run.state === 'settled' && (
          <>
            <div className="join-spacer" />
            <a className="btn btn-outline" href="/">Start another run</a>
          </>
        )}
      </div>
    </div>
  );
}
