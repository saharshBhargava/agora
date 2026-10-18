'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { api } from '@/lib/api';

export default function Home() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function start() {
    setBusy(true);
    setError(null);
    try {
      const { runId, shopperId } = await api.createRun();
      router.push(`/shopper?run=${encodeURIComponent(runId)}&person=${encodeURIComponent(shopperId)}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not start a run');
      setBusy(false);
    }
  }

  return (
    <>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 'var(--space-2)' }}>
        <h1>Dibs</h1>
        <p className="muted">Shop with your room watching. Claim what is yours, as it lands in the cart.</p>
      </div>
      {error && <p className="error" role="alert">{error}</p>}
      <button className="btn" onClick={start} disabled={busy}>
        {busy ? 'Starting…' : 'Start a run'}
      </button>
    </>
  );
}
