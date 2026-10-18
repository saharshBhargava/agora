'use client';
import { useRef, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { api } from '@/lib/api';
import { useRun } from '@/lib/socket';
import { formatCents } from '@/lib/money';
import { isLiveChip, listNames } from '@/lib/share';
import { Camera } from '@/components/Camera';
import { ReceiptMatch } from '@/components/ReceiptMatch';
import { SettleLines } from '@/components/SettleLines';
import type { Run } from '@/lib/types';

/** "Milk, $4.29, stays with Jake." / "Milk ($4.29) and Gum ($1.99) stay with Jake." / null when nothing does. */
export function staysWith(run: Run, shopperName: string): string | null {
  const items: { name: string; cents: number | null }[] = run.chips
    .filter((c) => isLiveChip(c) && c.claimers.length === 0)
    .map((c) => ({ name: c.name, cents: c.priceCents }));
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
  const { run, connected, ended } = useRun(runId || null, personId || null);
  const frameRef = useRef<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!runId || !personId) return <p className="error" role="alert">This link is missing its run.</p>;
  if (ended) return <p className="muted" role="status">This run has ended</p>;
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

  return (
    <div className="settle bleed">
      {run.payout ? (
        <section className="settle-hero" aria-label="Run settled">
          <span className="settle-hero-tag">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" strokeWidth="2" aria-hidden="true"><path d="M5 12l5 5 9-10" /></svg>
            <span>{run.state === 'partlySettled' ? 'Run partly settled' : 'Run settled · nobody chases anybody'}</span>
          </span>
          <h1 className="settle-hero-who">{shopperName} gets back</h1>
          <span className="money settle-hero-amount">{formatCents(run.payout.amountCents)}</span>
          <p className="settle-hero-note">
            {`Pushed to ${shopperName}'s card over Visa Direct (simulated in this build).`}{stays ? ` ${stays}` : ''}
          </p>
        </section>
      ) : (
        <header className="settle-head">
          <span className="wordmark" aria-hidden="true">dibs</span>
          <h1>Settle</h1>
        </header>
      )}

      <div className="settle-body">
        {!connected && <p className="muted" role="status">Reconnecting…</p>}
        {run.state === 'partlySettled' && <span className="badge">Partly settled</span>}

        {(run.state === 'open' || run.state === 'lastCall') && (
          <p className="muted">The run is still open. <a href={back}>Back to the cart</a></p>
        )}

        {run.state === 'locked' &&
          (isShopper ? (
            <>
              {mock ? (
                <button type="button" className="btn" disabled={busy} onClick={() => act(() => api.receipt(runId, ''))}>
                  Use printed receipt
                </button>
              ) : (
                <>
                  <div className="settle-photo">
                    <Camera
                      send={(m) => {
                        if (typeof m.jpegBase64 === 'string') frameRef.current = m.jpegBase64;
                        return true;
                      }}
                      enabled
                      region={null}
                      mockHref={mockHref}
                    />
                  </div>
                  <button
                    type="button"
                    className="btn"
                    disabled={busy}
                    onClick={() => act(async () => {
                      if (!frameRef.current) throw new Error('Point the camera at the receipt first');
                      await api.receipt(runId, frameRef.current);
                    })}
                  >
                    Photograph receipt
                  </button>
                </>
              )}
            </>
          ) : (
            <p className="muted" role="status">Waiting for the shopper to read the receipt.</p>
          ))}

        {hasResults && <SettleLines run={run} me={personId} canRetry={isShopper} busy={busy} onRetry={confirm} />}

        {run.receipt && (
          <ReceiptMatch
            receipt={run.receipt}
            chips={run.chips}
            canFix={isShopper && run.state === 'receipt'}
            compact={settled}
            busy={busy}
            onFix={(i, target) => void act(() => api.fixReceiptLine(runId, i, target))}
          />
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
