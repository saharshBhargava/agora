'use client';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { api } from '@/lib/api';
import { useRun } from '@/lib/socket';
import { useCountdown } from '@/lib/countdown';
import { useHighlight } from '@/lib/highlight';
import { formatCents } from '@/lib/money';
import { coverage, listNames, ringColor } from '@/lib/share';
import { tileColor } from '@/lib/tile';
import { Board } from '@/components/Board';
import { Camera, MockProps } from '@/components/Camera';
import { FixChipSheet } from '@/components/FixChipSheet';
import { UnclaimedList } from '@/components/UnclaimedList';
import { UndoToast } from '@/components/UndoToast';
import type { Chip } from '@/lib/types';

const UNDO_MS = 5000;
const NOTICE_MS = 4000;
const TIP = 'Tap the item on the screen to identify it';
const clock = (secs: number) => `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}`;

export default function ShopperScreen() {
  const params = useSearchParams();
  const router = useRouter();
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
  const [tip, setTip] = useState<string | null>(null);
  const endsAt = lastCallEndsAt ?? run?.lastCallEndsAt ?? null;
  const secs = useCountdown(run?.state === 'lastCall' ? endsAt : null);
  const dismissRemoved = useCallback(() => setRemoved(null), []);
  // Last call has no fixed length on the client: the first countdown value seen is the full bar.
  const lastCallTotal = useRef(0);
  if (secs !== null && secs > lastCallTotal.current) lastCallTotal.current = secs;
  if (run?.state !== 'lastCall') lastCallTotal.current = 0;

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

  useEffect(() => {
    if (!tip) return;
    const t = setTimeout(() => setTip(null), NOTICE_MS);
    return () => clearTimeout(t);
  }, [tip]);

  const chips = useMemo(() => (run?.chips ?? []).filter((c) => c.state !== 'removed' && !c.dropped), [run]);
  const highlight = useHighlight(chips, identifyingRegion ?? null);

  if (!runId || !personId) return <p className="error" role="alert">This link is missing its run.</p>;
  if (ended) return <p className="muted" role="status">This run has ended</p>;
  if (!run) return <p className="muted" role="status">{connected ? 'Loading the run' : 'Connecting'}</p>;
  if (personId !== run.shopperId) {
    return (
      <div className="card closed-panel">
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

  const settleHref = `/settle?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}${mock ? '&mock=1' : ''}`;
  // After the receipt the cart is closed: the shopper only moves on to settle.
  if (run.state === 'receipt' || run.state === 'settled' || run.state === 'partlySettled') {
    return (
      <div className="card card-lg closed-panel" role="group" aria-label="Cart closed">
        <h2>The cart is closed</h2>
        <p className="muted">Settle is next: read the receipt, then everyone&apos;s share is captured from their hold.</p>
        <a
          className="btn"
          href={settleHref}
          onClick={(e) => { e.preventDefault(); router.push(settleHref); }}
        >
          Go to settle
        </a>
      </div>
    );
  }

  const streaming = connected && (run.state === 'open' || run.state === 'lastCall');
  const locked = run.state === 'locked';
  const dupes = chips.filter((c) => c.duplicateOf && !kept.has(c.id));
  const mockHref = `/shopper?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}&mock=1`;
  const hint = !connected ? 'Reconnecting…' : notice ?? tip;
  const claimerNames = run.people.filter((p) => !p.isShopper).map((p) => p.name);
  const cover = coverage(run.people, chips);
  const unclaimedCents = cover.totalCents - cover.coveredCents;
  const barLabel = cover.totalCents === 0
    ? 'Nothing priced in the cart yet'
    : [...cover.segments.map((g) => `${g.name} covers ${formatCents(g.cents)}`), `${formatCents(unclaimedCents)} unclaimed`].join(', ');

  return (
    <div className="shop bleed">
      {locked && (
        <div className="shop-band shop-band-static">
          <span className="shop-band-eyebrow">Locked</span>
          <p className="shop-band-title">Head to the register. Claims are final now.</p>
        </div>
      )}
      {!(locked && mock) && (
        <div className={`shop-cam${locked ? ' cam-hidden' : ''}`}>
          {mock ? (
            <MockProps
              busy={busy}
              onPick={(name, imageBase64) => act(() => api.addChip(runId, { imageBase64, hint: name }))}
            />
          ) : (
            <Camera
              send={send}
              enabled={streaming}
              region={highlight?.region ?? null}
              label={highlight?.label ?? null}
              pending={highlight?.pending ?? true}
              mockHref={mockHref}
              persist
            />
          )}
          <div className="cam-bar">
            <span className="cam-pill">
              <span className={`live-dot${streaming ? '' : ' live-dot-off'}`} aria-hidden="true" />
              <span>{claimerNames.length ? `Streaming to ${listNames(claimerNames)}` : 'Streaming · nobody has joined yet'}</span>
            </span>
            <button type="button" className="cam-icon-btn" aria-label="Tap an item the camera missed" onClick={() => setTip(TIP)}>
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" strokeWidth="1.8" aria-hidden="true">
                <path d="M12 3v4M12 17v4M3 12h4M17 12h4" />
                <circle cx="12" cy="12" r="3" />
              </svg>
            </button>
          </div>
          {hint && <p className="live-notice" role="status">{hint}</p>}
          {run.state === 'lastCall' && (
            <div className="shop-band" role="status">
              <div className="shop-band-top">
                <span className="shop-band-eyebrow">Last call</span>
                <span className="money shop-band-count">{clock(secs ?? 0)}</span>
              </div>
              <p className="shop-band-title">
                {claimerNames.length ? `${listNames(claimerNames)} ${claimerNames.length === 1 ? 'sees' : 'see'} this too.` : 'Nobody else is in.'} Then the cart locks.
              </p>
              <div className="shop-band-bar" aria-hidden="true">
                <span style={{ width: `${lastCallTotal.current ? ((secs ?? 0) / lastCallTotal.current) * 100 : 0}%` }} />
              </div>
              <button type="button" className="btn btn-pill btn-pill-dark" disabled={busy} onClick={() => act(() => api.back(runId, personId))}>
                Back to cart
              </button>
            </div>
          )}
        </div>
      )}

      <div className={`shop-sheet${locked ? ' shop-sheet-locked' : ''}`}>
        {locked ? (
          <UnclaimedList
            run={run}
            personId={personId}
            mock={mock}
            onPutBack={(chipId) => void act(() => api.putBack(runId, chipId, personId))}
            onBack={() => void act(() => api.back(runId, personId))}
            onGoSettle={(href) => router.push(href)}
          />
        ) : (
          <>
            <div className="covered">
              <span className="covered-label">Covered by your housemates</span>
              <span className="money covered-amount" data-testid="covered">
                {formatCents(cover.coveredCents)} <span className="covered-of">of {formatCents(cover.totalCents)}</span>
              </span>
            </div>
            <div className="cover-bar" role="img" aria-label={barLabel}>
              {cover.totalCents > 0 && cover.segments.map((g) => (
                <span
                  key={g.id}
                  className="cover-seg"
                  data-segment={g.id}
                  style={{ width: `${(g.cents / cover.totalCents) * 100}%`, background: ringColor(run.people, g.id, personId) }}
                />
              ))}
            </div>

            {dupes.map((c) => (
              <div key={c.id} className="card dupe" role="group" aria-label={`${c.name} may be a duplicate`}>
                <div className="dupe-top">
                  <span className="cart-thumb dupe-thumb" style={{ '--tile': tileColor(c.id) } as React.CSSProperties} aria-hidden="true">
                    {c.photoUrl ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={c.photoUrl} alt="" />
                    ) : c.name.charAt(0)}
                  </span>
                  <span className="dupe-text">
                    <strong>Added twice?</strong>
                    <span className="muted">{c.name} showed up again</span>
                  </span>
                </div>
                <div className="dupe-actions">
                  <button type="button" className="btn btn-sm btn-outline" onClick={() => setKept((k) => new Set(k).add(c.id))}>Keep both</button>
                  <button type="button" className="btn btn-sm" onClick={() => send({ t: 'remove', chipId: c.id })}>Remove one</button>
                </div>
              </div>
            ))}

            <Board
              layout="rows"
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

            <div className="shop-spacer" />
            {actionError && <p className="error" role="alert">{actionError}</p>}
            {run.state === 'open' && (
              <button type="button" className="btn" disabled={busy} onClick={() => act(() => api.checkout(runId, personId))}>
                Check out
              </button>
            )}
          </>
        )}
        {locked && actionError && <p className="error" role="alert">{actionError}</p>}
      </div>

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
    </div>
  );
}
