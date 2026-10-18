'use client';
import { useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { api, type JoinResult } from '@/lib/api';
import { HeldBadge } from '@/components/HeldBadge';
import { formatCents } from '@/lib/money';

export default function JoinScreen() {
  const params = useSearchParams();
  const runId = params.get('run') ?? '';
  const name = params.get('name') || 'A';
  const capParam = Number.parseInt(params.get('cap') ?? '', 10);
  const capCents = Number.isFinite(capParam) && capParam > 0 ? capParam : 4000;
  const decline = params.get('decline') === '1';

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [joined, setJoined] = useState<JoinResult | null>(null);

  async function join() {
    setBusy(true);
    setError(null);
    try {
      setJoined(await api.join(runId, name, capCents, { decline }));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not join');
    } finally {
      setBusy(false);
    }
  }

  if (!runId) return <p className="error" role="alert">This link is missing its run.</p>;

  return (
    <>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 'var(--space-2)' }}>
        <h1>Join the run</h1>
        <p className="muted">
          You are {name}. Your cap is {formatCents(capCents)}; that amount is held on your card
          until the run settles, and whatever you do not claim is released.
        </p>
        {joined && (
          <div className="card" style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-1)' }}>
            <HeldBadge cents={joined.auth.authorizedCents} approvalCode={joined.auth.approvalCode} />
            <p className="muted">You are in the room. Watch the grid for chips to claim.</p>
          </div>
        )}
        {error && <p className="error" role="alert">{error}</p>}
      </div>
      {!joined && (
        <button className="btn" onClick={join} disabled={busy}>
          {busy ? 'Joining…' : 'Join'}
        </button>
      )}
    </>
  );
}
