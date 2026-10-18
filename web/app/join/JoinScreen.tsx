'use client';
import { useEffect, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { api, TEST_CARD, type JoinResult } from '@/lib/api';
import { HeldBadge } from '@/components/HeldBadge';
import { Avatar } from '@/components/Avatar';
import { wholeCents } from '@/lib/money';
import { isLiveChip, listNames } from '@/lib/share';
import { runTitle, tileColor } from '@/lib/tile';
import type { Person, Run } from '@/lib/types';


function CardIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true">
      <rect x="3" y="6" width="18" height="12" rx="2" />
      <path d="M3 10h18" />
    </svg>
  );
}

export default function JoinScreen() {
  const params = useSearchParams();
  const router = useRouter();
  const runId = params.get('run') ?? '';
  const name = params.get('name') || 'A';
  const capParam = Number.parseInt(params.get('cap') ?? '', 10);
  const capCents = Number.isFinite(capParam) && capParam > 0 ? capParam : 4000;
  const decline = params.get('decline') === '1';

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [joined, setJoined] = useState<JoinResult | null>(null);
  const [run, setRun] = useState<Run | null>(null);

  useEffect(() => {
    if (!runId) return;
    let live = true;
    (async () => {
      try {
        const r = await api.getRun(runId);
        if (live) setRun(r);
      } catch {
        /* the run card falls back to plain copy; join still reports its own error */
      }
    })();
    return () => { live = false; };
  }, [runId]);

  async function join() {
    setBusy(true);
    setError(null);
    try {
      const res = await api.join(runId, name, capCents, { decline });
      setJoined(res);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not join');
    } finally {
      setBusy(false);
    }
  }

  if (!runId) return <p className="error" role="alert">This link is missing its run.</p>;

  const shopper = run?.people.find((p) => p.id === run.shopperId);
  const shopperName = shopper?.name ?? 'the shopper';
  const claimers = (run?.people ?? []).filter((p) => !p.isShopper);
  // The joiner, shown dashed until they are in.
  const meId = joined?.personId ?? '__joiner';
  const joiner: Person = {
    id: meId, name, initial: (name.trim()[0] ?? '?').toUpperCase(), isShopper: false,
    authorizedCents: null, authId: null, approvalCode: null, payoutPan: null,
  };
  const people = [...(shopper ? [shopper] : []), ...claimers.filter((p) => p.id !== meId), joiner];
  const tiles = (run?.chips ?? []).filter(isLiveChip).sort((a, b) => b.addedAt - a.addedAt).slice(0, 3);
  const others = claimers.filter((p) => p.id !== meId).map((p) => p.name);
  const who = [
    shopper ? `${shopper.name} is shopping` : null,
    others.length ? `${listNames(others)} ${others.length === 1 ? 'is' : 'are'} in` : null,
  ].filter(Boolean).join(' · ');

  return (
    <>
      <div className="join-top">
        <span className="wordmark" aria-label="Dibs">dibs</span>
        {shopper && <span className="muted" style={{ fontSize: 'var(--fs-sm)' }}>Invited by {shopper.name}</span>}
      </div>

      <section className="card card-lg join-run" aria-label="The run">
        <div className="join-run-title">
          <span className="eyebrow">Live run</span>
          <h1>{run ? runTitle(shopper?.name, run.store) : 'Join the run'}</h1>
        </div>
        <div className="join-who">
          <span className="avatars">
            {people.map((p) => (
              <Avatar key={p.id} person={p} people={people} me={meId} dashed={p.id === meId && !joined} />
            ))}
          </span>
          {who && <span>{who}</span>}
        </div>
        {tiles.length > 0 && (
          <div className="join-cart">
            <span className="muted" style={{ fontSize: 'var(--fs-sm)' }}>In the cart so far</span>
            <div className="join-tiles" role="list">
              {tiles.map((c) => (
                <div key={c.id} role="listitem" className="join-tile" style={{ background: tileColor(c.id) }} aria-label={c.name}>
                  {c.photoUrl ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={c.photoUrl} alt="" />
                  ) : (
                    <span aria-hidden="true">{c.name.charAt(0)}</span>
                  )}
                </div>
              ))}
            </div>
          </div>
        )}
      </section>

      <div className="join-hold">
        <span className="join-hold-label">Your hold</span>
        <span className="money join-hold-amount">{wholeCents(capCents)}</span>
        <p className="join-hold-copy">
          Held on your card while the run is open. Only what you claim is captured; the rest is released when {shopperName} checks out.
        </p>
        <span className="join-card"><CardIcon /><span>Visa ending {TEST_CARD.number.slice(-4)}</span></span>
      </div>

      {joined && (
        <div className="card join-done">
          <HeldBadge cents={joined.auth.authorizedCents} approvalCode={joined.auth.approvalCode} />
          <p className="muted">You are in. Watch the cart and claim what is yours.</p>
        </div>
      )}
      {error && <p className="error" role="alert">{error}</p>}

      <div className="join-spacer" />

      {joined ? (
        <button
          type="button"
          className="btn"
          onClick={() => router.push(`/claim?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(joined.personId)}`)}
        >
          Start claiming
        </button>
      ) : (
        <button type="button" className="btn" onClick={join} disabled={busy}>
          {busy ? 'Joining…' : `Join ${shopper ? `${shopper.name}'s` : 'the'} run`}
        </button>
      )}
      <p className="join-caption">A Visa authorization, not a charge.</p>
    </>
  );
}
