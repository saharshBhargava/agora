'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { api } from '@/lib/api';
import { useRun } from '@/lib/socket';
import { useCountdown } from '@/lib/countdown';
import { Board } from '@/components/Board';
import { Camera, MockProps } from '@/components/Camera';
import { FixChipSheet } from '@/components/FixChipSheet';
import { UnclaimedList } from '@/components/UnclaimedList';
import { UndoToast } from '@/components/UndoToast';
import type { Chip } from '@/lib/types';

const UNDO_MS = 5000;
const NOTICE_MS = 4000;

export default function ShopperScreen() {
  const params = useSearchParams();
  const runId = params.get('run') ?? '';
  const personId = params.get('person') ?? '';
  const mock = params.get('mock') === '1';
  const { run, send, connected, lastCallEndsAt, identifyingRegion, errorEvent, ended } = useRun(runId || null, personId || null);

  const [fixing, setFixing] = useState<Chip | null>(null);
  const [removed, setRemoved] = useState<{ key: number; chip: Chip } | null>(null);
  const [kept, setKept] = useState<Set<string>>(new Set());
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const endsAt = lastCallEndsAt ?? run?.lastCallEndsAt ?? null;
  const secs = useCountdown(run?.state === 'lastCall' ? endsAt : null);
  const dismissRemoved = useCallback(() => setRemoved(null), []);

  // A new identify attempt (a region) after an error clears the hint. Declared before the error effect so an error wins a tie.
  useEffect(() => {
    if (identifyingRegion) setNotice(null);
  }, [identifyingRegion]);
  useEffect(() => {
    if (!errorEvent) return;
    setNotice(errorEvent.reason === 'identify failed' ? "Couldn't identify. Tap it again or name it" : errorEvent.reason);
    const t = setTimeout(() => setNotice(null), NOTICE_MS);
    return () => clearTimeout(t);
  }, [errorEvent]);

  const chips = useMemo(() => (run?.chips ?? []).filter((c) => c.state !== 'removed' && !c.dropped), [run]);

  if (!runId || !personId) return <p className="error" role="alert">This link is missing its run.</p>;
  if (ended) return <p className="muted" role="status">This run has ended</p>;
  if (!run) return <p className="muted" role="status">{connected ? 'Loading the run' : 'Connecting'}</p>;
  if (personId !== run.shopperId) {
    return (
      <div className="card">
        <p>This page is for the shopper.</p>
        <a className="btn" href={`/claim?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}`}>Go to claim</a>
      </div>
    );
  }

  const act = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setActionError(null);
    try {
      await fn();
    } catch (e) {
      setActionError(e instanceof Error ? e.message : 'Something went wrong');
    } finally {
      setBusy(false);
    }
  };

  // After the receipt the cart is closed: the shopper only moves on to settle.
  if (run.state === 'receipt' || run.state === 'settled' || run.state === 'partlySettled') {
    return (
      <div className="card" role="group" aria-label="Cart closed">
        <p>The cart is closed. Settle is next.</p>
        <a className="btn" href={`/settle?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}${mock ? '&mock=1' : ''}`}>
          Go to settle
        </a>
      </div>
    );
  }

  const streaming = connected && (run.state === 'open' || run.state === 'lastCall');
  const locked = run.state === 'locked';
  const dupes = chips.filter((c) => c.duplicateOf && !kept.has(c.id));
  const mockHref = `/shopper?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}&mock=1`;
  const hint = !connected ? 'Reconnecting…' : notice;

  return (
    <>
      {!locked && (
        <div className="live">
          {mock ? (
            <MockProps
              busy={busy}
              onPick={(name, imageBase64) => act(() => api.addChip(runId, { imageBase64, hint: name }))}
            />
          ) : (
            <Camera send={send} enabled={streaming} region={identifyingRegion} mockHref={mockHref} />
          )}
          {hint && <p className="live-notice" role="status">{hint}</p>}
        </div>
      )}

      {!locked && run.state === 'open' && (
        <button type="button" className="btn checkout-btn" disabled={busy} onClick={() => act(() => api.checkout(runId, personId))}>
          Checkout
        </button>
      )}
      {actionError && <p className="error" role="alert">{actionError}</p>}

      {dupes.map((c) => (
        <div key={c.id} className="card dupe" role="group" aria-label={`${c.name} may be a duplicate`}>
          <span>Added twice? <strong>{c.name}</strong></span>
          <div className="dupe-actions">
            <button type="button" className="btn btn-secondary" onClick={() => setKept((k) => new Set(k).add(c.id))}>Keep both</button>
            <button type="button" className="btn" onClick={() => send({ t: 'remove', chipId: c.id })}>Remove one</button>
          </div>
        </div>
      ))}

      {run.state === 'lastCall' && (
        <div className="banner" role="status">
          <span>Last call · {secs ?? 0}s</span>
          <button type="button" className="btn btn-secondary" disabled={busy} onClick={() => act(() => api.back(runId, personId))}>
            Back to cart
          </button>
        </div>
      )}

      {locked ? (
        <UnclaimedList
          run={run}
          personId={personId}
          mock={mock}
          onPutBack={(chipId) => void act(() => api.putBack(runId, chipId, personId))}
          onBack={() => void act(() => api.back(runId, personId))}
        />
      ) : (
        <>
          <Board
            chips={chips}
            people={run.people}
            me={personId}
            authorizedCents={null}
            taxRate={run.taxRate}
            onClaim={(chipId) => send({ t: 'claim', chipId })}
            onLeave={(chipId) => send({ t: 'leave', chipId })}
            removeZone
            onRemove={(chipId) => {
              const chip = chips.find((c) => c.id === chipId);
              if (!chip) return;
              if (!send({ t: 'remove', chipId })) return;
              setRemoved({ key: Date.now(), chip });
            }}
            onTap={(chipId) => setFixing(chips.find((c) => c.id === chipId) ?? null)}
          />
        </>
      )}

      {removed && (
        <UndoToast
          key={removed.key}
          label={`Removed ${removed.chip.name}`}
          ms={UNDO_MS}
          onUndo={() => {
            send({ t: 'undoRemove', chipId: removed.chip.id });
            setRemoved(null);
          }}
          onDismiss={dismissRemoved}
        />
      )}

      {fixing && (
        <FixChipSheet
          chip={fixing}
          onClose={() => setFixing(null)}
          onSave={(fix) => {
            const id = fixing.id;
            setFixing(null);
            if (Object.keys(fix).length > 0) void act(() => api.fixChip(runId, id, personId, fix));
          }}
        />
      )}
    </>
  );
}
