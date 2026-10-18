'use client';
import type { CSSProperties, MouseEvent } from 'react';
import type { Run } from '@/lib/types';
import { formatCents } from '@/lib/money';
import { tileColor } from '@/lib/tile';

/** After lock: chips nobody claimed. Mine is the default; Put back drops the chip from the run. */
export function UnclaimedList({
  run,
  personId,
  mock = false,
  onPutBack,
  onBack,
  onGoSettle,
}: {
  run: Run;
  personId: string;
  /** Keeps `mock=1` on the settle link so sample items stay on. */
  mock?: boolean;
  onPutBack: (chipId: string) => void;
  onBack: () => void;
  /** Client-side navigation to settle (keeps the camera stream for the receipt). Plain link otherwise. */
  onGoSettle?: (href: string) => void;
}) {
  const items = run.chips.filter(
    (c) => c.claimers.length === 0 && c.state === 'locked' && !c.dropped,
  );
  const href = `/settle?run=${encodeURIComponent(run.id)}&person=${encodeURIComponent(personId)}${mock ? '&mock=1' : ''}`;
  const go = (e: MouseEvent<HTMLAnchorElement>) => {
    if (!onGoSettle) return;
    e.preventDefault();
    onGoSettle(href);
  };
  return (
    <section className="unclaimed" aria-label="Unclaimed chips">
      <div className="unclaimed-head">
        <h2>Nobody claimed these</h2>
        <p className="muted">
          {items.length === 0
            ? 'Everything has an owner.'
            : "They stay yours by default. Put back anything you don't want before the register."}
        </p>
      </div>
      <ul className="unclaimed-list">
        {items.map((c) => (
          <li key={c.id} className={`card unclaimed-row${c.putBack ? ' unclaimed-row-back' : ''}`}>
            <div className="unclaimed-info">
              <span className="unclaimed-thumb" style={{ '--tile': tileColor(c.id) } as CSSProperties} aria-hidden="true">
                {c.photoUrl ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={c.photoUrl} alt="" />
                ) : c.name.charAt(0)}
              </span>
              <span className="unclaimed-text">
                <span className="unclaimed-name">{c.name}</span>
                {c.putBack && <span className="muted">Putting back</span>}
              </span>
              <span>{c.priceCents === null ? '~$?' : formatCents(c.priceCents)}</span>
            </div>
            {!c.putBack && (
              <div className="unclaimed-actions">
                <button type="button" className="btn btn-sm" aria-pressed="true">Mine</button>
                <button type="button" className="btn btn-sm btn-choice" aria-pressed="false" onClick={() => onPutBack(c.id)}>
                  Put back
                </button>
              </div>
            )}
          </li>
        ))}
      </ul>
      <div className="unclaimed-footer">
        <a className="btn" href={href} onClick={go}>I&apos;ve paid · snap the receipt</a>
        <button type="button" className="btn btn-sm btn-ghost" onClick={onBack}>Back to cart</button>
      </div>
    </section>
  );
}
