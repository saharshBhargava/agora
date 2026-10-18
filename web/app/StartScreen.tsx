'use client';
import { useEffect, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { api } from '@/lib/api';
import { useRun } from '@/lib/socket';
import { wholeCents } from '@/lib/money';
import { capitalize } from '@/lib/tile';
import { Avatar } from '@/components/Avatar';

const HOLD_CENTS = 4000;
const TOAST_MS = 2500;

function ShareIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <path d="M12 15V3M7 8l5-5 5 5M5 13v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6" />
    </svg>
  );
}

/** Send the join link: the share sheet when there is one, otherwise copy it. Returns what to tell the shopper. */
export async function shareJoinLink(url: string, title: string): Promise<string | null> {
  const nav = navigator as Navigator & { share?: (d: ShareData) => Promise<void> };
  if (typeof nav.share === 'function') {
    try {
      await nav.share({ title, text: `Join ${title} on Dibs`, url });
      return null;
    } catch (e) {
      if (e instanceof Error && e.name === 'AbortError') return null;
      // Fall through to copying.
    }
  }
  try {
    await navigator.clipboard.writeText(url);
    return 'Link copied';
  } catch {
    return `Copy this link: ${url}`;
  }
}

function Landing() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function start() {
    setBusy(true);
    setError(null);
    try {
      const { runId, shopperId } = await api.createRun();
      router.replace(`/?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(shopperId)}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not start a run');
      setBusy(false);
    }
  }

  return (
    <>
      <div className="landing-hero">
        <h1 className="wordmark">dibs</h1>
        <p className="join-hold-copy">Shop with your room watching. Claim what is yours, as it lands in the cart.</p>
      </div>
      {error && <p className="error" role="alert">{error}</p>}
      <button className="btn" onClick={start} disabled={busy}>
        {busy ? 'Starting…' : 'Start a run'}
      </button>
    </>
  );
}

function Invite({ runId, personId }: { runId: string; personId: string }) {
  const router = useRouter();
  const { run } = useRun(runId, personId);
  const [toast, setToast] = useState<string | null>(null);
  const [joinUrl, setJoinUrl] = useState(`/join?run=${encodeURIComponent(runId)}`);
  useEffect(() => setJoinUrl(`${window.location.origin}/join?run=${encodeURIComponent(runId)}`), [runId]);
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), TOAST_MS);
    return () => clearTimeout(t);
  }, [toast]);

  const store = run?.store ? capitalize(run.store) : null;
  const shopper = run?.people.find((p) => p.id === run.shopperId);
  const title = shopper && store ? `${shopper.name}'s ${store} run` : 'the run';
  const claimers = (run?.people ?? []).filter((p) => !p.isShopper);
  const shopperHref = `/shopper?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(personId)}`;

  return (
    <>
      <span className="wordmark" aria-hidden="true">dibs</span>
      <div className="start-intro">
        <h1>{store ? `Your ${store} run is open` : 'Your run is open'}</h1>
        <p className="join-hold-copy">
          Send the link to your house chat. Anyone can join from home until you check out. Each person puts a {wholeCents(HOLD_CENTS)} hold on their own card.
        </p>
      </div>

      <button type="button" className="btn btn-blue" onClick={async () => setToast(await shareJoinLink(joinUrl, title))}>
        <ShareIcon />
        <span>Send link to the house chat</span>
      </button>

      <div className="card start-qr">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={`/api/runs/${encodeURIComponent(runId)}/qr`} alt="QR code to join the run" width={96} height={96} />
        <div className="start-qr-text">
          <strong>Next to you? Scan to join</strong>
          <span className="muted">Same link as the house chat, for anyone standing beside you.</span>
        </div>
      </div>

      <section className="start-people" aria-label="In the run">
        <span className="muted" style={{ fontSize: 'var(--fs-sm)' }}>In the run</span>
        <ul className="start-list">
          {claimers.map((p) => (
            <li key={p.id} className="card start-person">
              <Avatar person={p} people={run!.people} me={personId} size="sm" />
              <span className="start-person-name">{p.name}</span>
              <span className="start-held">{p.authorizedCents !== null ? `${wholeCents(p.authorizedCents)} held` : 'Joining…'}</span>
            </li>
          ))}
          <li className="start-waiting">{claimers.length ? 'Waiting for more…' : 'Waiting for your housemates…'}</li>
        </ul>
      </section>

      <div className="join-spacer" />
      <button type="button" className="btn" onClick={() => router.push(shopperHref)}>Clip phone to cart and start</button>
      {toast && <div className="toast" role="status"><span>{toast}</span></div>}
    </>
  );
}

export default function StartScreen() {
  const params = useSearchParams();
  const runId = params.get('run');
  const personId = params.get('person');
  return runId && personId ? <Invite runId={runId} personId={personId} /> : <Landing />;
}
