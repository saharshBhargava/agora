'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { api } from '@/lib/api';
import { ApiError } from '@/lib/api-error';
import { useRun } from '@/lib/socket';
import { formatCents } from '@/lib/money';
import { myShare } from '@/lib/share';
import { Board } from '@/components/Board';
import { LiveView } from '@/components/LiveView';
import { WishSheet } from '@/components/WishSheet';
import type { Chip } from '@/lib/types';

const NOTICE_MS = 4000;
const RAISE_STEP_CENTS = 2000;

export default function ClaimScreen() {
  const params = useSearchParams();
  const router = useRouter();
  const runId = params.get('run') ?? '';
  const personId = params.get('person') ?? '';
  const { run, send, connected, lastFrame, errorEvent } = useRun(runId || null, personId || null);

  const [large, setLarge] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [overCap, setOverCap] = useState<Chip | null>(null);
  const [raiseOff, setRaiseOff] = useState(false);
  const [busy, setBusy] = useState(false);
  const dismissOver = useCallback(() => setOverCap(null), []);

  const me = run?.people.find((p) => p.id === personId);
  const unknown = !!run && !me;
  useEffect(() => {
    if (unknown) router.replace(`/join?run=${encodeURIComponent(runId)}`);
  }, [unknown, router, runId]);

  const noPerson = !!runId && !personId;
  useEffect(() => {
    if (noPerson) router.replace(`/join?run=${encodeURIComponent(runId)}`);
  }, [noPerson, router, runId]);

  useEffect(() => {
    if (!errorEvent) return;
    setNotice(errorEvent.reason);
    const t = setTimeout(() => setNotice(null), NOTICE_MS);
    return () => clearTimeout(t);
  }, [errorEvent]);

  useEffect(() => {
    if (!overCap) return;
    const t = setTimeout(() => setOverCap(null), 6000);
    return () => clearTimeout(t);
  }, [overCap]);

  const chips = useMemo(() => (run?.chips ?? []).filter((c) => c.state !== 'removed' && !c.dropped), [run]);

  if (!runId) return <p className="error" role="alert">This link is missing its run.</p>;
  if (!personId) return <p className="muted" role="status">Joining</p>;
  if (!run || !me) return <p className="muted" role="status">{connected ? 'Loading the run' : 'Connecting'}</p>;
  if (me.isShopper) {
    return (
      <div className="card">
        <p>This page is for claimers.</p>
        <a className="btn" href={`/shopper?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}`}>Go to the cart</a>
      </div>
    );
  }

  const shopper = run.people.find((p) => p.id === run.shopperId);
  const open = run.state === 'open' || run.state === 'lastCall';
  const cap = me.authorizedCents ?? 0;
  const mine = chips.filter((c) => c.claimers.includes(personId));
  const trayTotal = mine.reduce((s, c) => s + myShare(c.priceCents, c.claimers, personId), 0);
  const settleHref = `/settle?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}`;

  const raise = async () => {
    setBusy(true);
    try {
      await api.raise(runId, personId, cap + RAISE_STEP_CENTS);
      setOverCap(null);
    } catch (e) {
      if (e instanceof ApiError && e.status === 403) setRaiseOff(true);
      else setNotice(e instanceof Error ? e.message : 'Could not raise your cap');
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <button type="button" className="liveview-toggle" aria-label="Toggle live view size" onClick={() => setLarge((l) => !l)}>
        <LiveView frame={lastFrame} shopperName={shopper?.name ?? 'Shopper'} small={!large} />
      </button>
      {!connected && <p className="muted" role="status">Reconnecting…</p>}

      {run.state === 'lastCall' && <div className="banner" role="status"><span>{shopper?.name ?? 'The shopper'} is checking out · last call</span></div>}
      {!open && (
        <div className="banner" role="status">
          <span>Your tray is {formatCents(trayTotal)} across {mine.length} {mine.length === 1 ? 'item' : 'items'}</span>
          <a className="btn" href={settleHref}>See settle</a>
        </div>
      )}

      <Board
        chips={chips}
        people={run.people}
        me={personId}
        authorizedCents={me.authorizedCents ?? 0}
        taxRate={run.taxRate}
        onClaim={(chipId) => send({ t: 'claim', chipId })}
        onLeave={(chipId) => send({ t: 'leave', chipId })}
        onOverCap={(chip) => { setRaiseOff(false); setOverCap(chip); }}
      />

      {open && <WishSheet busy={busy} onWish={async (name) => { try { await api.wish(runId, name, personId); } catch (e) { setNotice(e instanceof Error ? e.message : 'Could not add the wish'); } }} />}

      {overCap && (
        <div className="toast claim-toast" role="status">
          <span>{raiseOff ? 'Raising your cap is off for this run' : 'Over your cap. Raise it?'}</span>
          {!raiseOff && (
            <button type="button" className="toast-action" disabled={busy} onClick={raise}>
              Raise to {formatCents(cap + RAISE_STEP_CENTS)}
            </button>
          )}
          <button type="button" className="toast-action" onClick={dismissOver}>Dismiss</button>
        </div>
      )}
      {notice && !overCap && <div className="toast" role="status"><span>{notice}</span></div>}
    </>
  );
}
