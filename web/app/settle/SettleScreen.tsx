'use client';
import { useRef, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { api } from '@/lib/api';
import { useRun } from '@/lib/socket';
import { Camera } from '@/components/Camera';
import { ReceiptMatch } from '@/components/ReceiptMatch';
import { SettleLines } from '@/components/SettleLines';

export default function SettleScreen() {
  const params = useSearchParams();
  const runId = params.get('run') ?? '';
  const personId = params.get('person') ?? '';
  const mock = params.get('mock') === '1';
  const { run, connected } = useRun(runId || null, personId || null);
  const frameRef = useRef<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!runId || !personId) return <p className="error" role="alert">This link is missing its run.</p>;
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

  return (
    <div className="settle">
      <h1>Settle</h1>
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

      {run.receipt && (
        <ReceiptMatch
          receipt={run.receipt}
          chips={run.chips}
          canFix={isShopper && run.state === 'receipt'}
          busy={busy}
          onFix={(i, target) => void act(() => api.fixReceiptLine(runId, i, target))}
        />
      )}

      {canConfirm && run.state === 'receipt' && (
        <button type="button" className="btn" disabled={busy} onClick={confirm}>Confirm & charge</button>
      )}
      {!isShopper && run.state === 'receipt' && <p className="muted" role="status">Waiting for the shopper to confirm.</p>}

      {hasResults && <SettleLines run={run} canRetry={isShopper} busy={busy} onRetry={confirm} />}
      {error && <p className="error" role="alert">{error}</p>}
    </div>
  );
}
