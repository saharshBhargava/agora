'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { api } from '@/lib/api';
import { ApiError } from '@/lib/api-error';
import { useRun } from '@/lib/socket';
import { useCountdown } from '@/lib/countdown';
import { useHighlight } from '@/lib/highlight';
import { formatCents, wholeCents } from '@/lib/money';
import { myShare, roomFor } from '@/lib/share';
import { runTitle, tileColor } from '@/lib/tile';
import { Board } from '@/components/Board';
import { AvatarStack } from '@/components/Avatar';
import { LiveView } from '@/components/LiveView';
import { WishSheet } from '@/components/WishSheet';
import type { Chip } from '@/lib/types';
import { visibleChip } from '@/lib/visible';

const NOTICE_MS = 4000;
const RAISE_STEP_CENTS = 2000;

export default function ClaimScreen() {
  const params = useSearchParams();
  const router = useRouter();
  const runId = params.get('run') ?? '';
  const personId = params.get('person') ?? '';
  const { run, send, connected, lastFrame, lastCallEndsAt, identifyingRegion, errorEvent, ended } = useRun(runId || null, personId || null);
  const secs = useCountdown(run?.state === 'lastCall' ? (lastCallEndsAt ?? run.lastCallEndsAt ?? null) : null);

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
    const on = (e: KeyboardEvent) => e.key === 'Escape' && setOverCap(null);
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  }, [overCap]);

  const chips = useMemo(() => (run?.chips ?? []).filter((c) => visibleChip(c)), [run]);
  const highlight = useHighlight(chips, identifyingRegion ?? null);

  if (!runId) return <p className="error" role="alert">This link is missing its run.</p>;
  if (!personId) return <p className="muted" role="status">Joining</p>;
  if (ended) return <p className="muted" role="status">This run has ended</p>;
  if (!run || !me) return <p className="muted" role="status">{connected ? 'Loading the run' : 'Connecting'}</p>;
  if (me.isShopper) {
    return (
      <div className="card closed-panel">
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
  const room = roomFor(mine.map((c) => c.priceCents ?? 0), cap, run.taxRate);
  const settleHref = `/settle?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}`;
  const others = run.people.filter((p) => p.id !== personId);
  const stack = [...others, me];

  const raise = async () => {
    const chip = overCap;
    setBusy(true);
    try {
      await api.raise(runId, personId, cap + RAISE_STEP_CENTS);
      setOverCap(null);
      // The raise was for this chip: claim it now that it fits.
      if (chip) send({ t: 'claim', chipId: chip.id });
    } catch (e) {
      if (e instanceof ApiError && e.status === 403) setRaiseOff(true);
      else setNotice(e instanceof Error ? e.message : 'Could not raise your cap');
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <header className="claim-head">
        <div className="claim-title">
          <h1>{runTitle(shopper?.name, run.store)}</h1>
          <span className="claim-status">
            <span className={`live-dot${open ? '' : ' live-dot-off'}`} aria-hidden="true" />
            <span>{open ? 'Live' : 'Closed'} · {run.people.length} in the run</span>
          </span>
        </div>
        <AvatarStack list={stack} people={run.people} me={personId} size="sm" label={`In the run: ${stack.map((p) => p.name).join(', ')}`} />
      </header>

      <button type="button" className="liveview-toggle" aria-label="Toggle live view size" onClick={() => setLarge((l) => !l)}>
        <LiveView frame={lastFrame} shopperName={shopper?.name ?? 'Shopper'} small={!large} highlight={highlight} />
      </button>

      <div className="share-row">
        <div className="share-main">
          <span className="share-label">Your share</span>
          <span className="money share-big">{formatCents(trayTotal)}</span>
        </div>
        {me.authorizedCents !== null && (
          <div className={`share-side${room < 0 || overCap ? ' share-over' : ''}`} data-testid="held">
            <div><strong>{formatCents(me.authorizedCents)}</strong> held</div>
            <div><strong className="room-num">{formatCents(room)}</strong> room left</div>
            {me.approvalCode && <div className="mono">auth {me.approvalCode}</div>}
          </div>
        )}
      </div>
      {!connected && <p className="muted" role="status">Reconnecting…</p>}

      {run.state === 'lastCall' && (
        <div className="banner banner-live" role="status">
          <span>{`${shopper?.name ?? 'The shopper'} is checking out · last call · ${secs ?? 0}s`}</span>
        </div>
      )}
      {!open && (
        <div className="banner" role="status">
          <span>Your tray is {formatCents(trayTotal)} across {mine.length} {mine.length === 1 ? 'item' : 'items'}</span>
          <a className="btn btn-sm" href={settleHref}>See settle</a>
        </div>
      )}

      <div className="section-head">
        <div className="section-title">
          <h2>In the cart</h2>
          <span className="section-hint">Hold a chip, drag it to your tray</span>
        </div>
        {open && <WishSheet busy={busy} onWish={async (name) => { try { await api.wish(runId, name, personId); } catch (e) { setNotice(e instanceof Error ? e.message : 'Could not add the wish'); } }} />}
      </div>

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

      {overCap && (
        <div className="sheet-backdrop sheet-backdrop-light" onClick={dismissOver}>
          <div className="sheet overcap" role="dialog" aria-label="Over your cap" onClick={(e) => e.stopPropagation()}>
            <div className="overcap-item">
              <span className="overcap-thumb" style={{ '--tile': tileColor(overCap.id) } as React.CSSProperties} aria-hidden="true">
                {overCap.photoUrl ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={overCap.photoUrl} alt="" />
                ) : overCap.name.charAt(0)}
              </span>
              <span className="overcap-text">
                <strong>{overCap.name}</strong>
                <span className="muted">
                  {overCap.priceCents === null ? 'Price not known yet' : formatCents(overCap.priceCents)} · more than your {formatCents(Math.max(0, room))} room
                </span>
              </span>
            </div>
            {raiseOff ? (
              <p className="overcap-title">Raising your cap is off for this run</p>
            ) : (
              <>
                <p className="overcap-title">Over your cap. Raise it to {wholeCents(cap + RAISE_STEP_CENTS)}?</p>
                <p className="join-hold-copy">Your hold grows by {wholeCents(RAISE_STEP_CENTS)}. Only what you claim is captured.</p>
                <button type="button" className="btn" disabled={busy} onClick={raise}>
                  Raise to {wholeCents(cap + RAISE_STEP_CENTS)} and claim
                </button>
              </>
            )}
            <button type="button" className="btn btn-sm btn-ghost" onClick={dismissOver}>Not now</button>
          </div>
        </div>
      )}
      {notice && !overCap && <div className="toast" role="status"><span>{notice}</span></div>}
    </>
  );
}
