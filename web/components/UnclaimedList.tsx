'use client';
import type { Run } from '@/lib/types';
import { formatCents } from '@/lib/money';

/** After lock: chips nobody claimed. Mine is the default; Put back drops the chip from the run. */
export function UnclaimedList({
  run,
  personId,
  mock = false,
  onPutBack,
  onBack,
}: {
  run: Run;
  personId: string;
  /** Keeps `mock=1` on the settle link so the demo stays in mock mode. */
  mock?: boolean;
  onPutBack: (chipId: string) => void;
  onBack: () => void;
}) {
  const items = run.chips.filter(
    (c) => c.claimers.length === 0 && c.state === 'locked' && !c.dropped,
  );
  return (
    <section className="unclaimed" aria-label="Unclaimed chips">
      <h2>Locked</h2>
      <p className="muted">
        {items.length === 0
          ? 'Everything has an owner.'
          : 'Nobody claimed these. They are yours unless you put them back.'}
      </p>
      <ul className="unclaimed-list">
        {items.map((c) => (
          <li key={c.id} className="card unclaimed-row">
            <div className="unclaimed-info">
              <span className="unclaimed-name">{c.name}</span>
              <span className="muted">{c.priceCents === null ? '~$?' : formatCents(c.priceCents)}</span>
            </div>
            <div className="unclaimed-actions">
              <button type="button" className={`btn ${c.putBack ? 'btn-secondary' : ''}`} aria-pressed={!c.putBack} disabled={c.putBack}>
                Mine
              </button>
              <button type="button" className={`btn ${c.putBack ? '' : 'btn-secondary'}`} aria-pressed={c.putBack} disabled={c.putBack} onClick={() => onPutBack(c.id)}>
                Put back
              </button>
            </div>
          </li>
        ))}
      </ul>
      <div className="unclaimed-footer">
        <button type="button" className="btn btn-secondary" onClick={onBack}>Back to cart</button>
        <a className="btn" href={`/settle?run=${encodeURIComponent(run.id)}&person=${encodeURIComponent(personId)}${mock ? '&mock=1' : ''}`}>Go to settle</a>
      </div>
    </section>
  );
}
