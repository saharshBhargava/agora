'use client';
import { useState } from 'react';
import type { Chip, ReceiptState } from '@/lib/types';
import { formatCents } from '@/lib/money';

/** Receipt lines with the matched chip and confidence. Unmatched lines offer Pair… / Mine (shopper only). */
export function ReceiptMatch({
  receipt,
  chips,
  canFix,
  onFix,
  busy = false,
}: {
  receipt: ReceiptState;
  chips: Chip[];
  canFix: boolean;
  busy?: boolean;
  onFix: (lineIndex: number, target: { chipId: string } | 'mine') => void;
}) {
  const [pairing, setPairing] = useState<number | null>(null);
  const matchedIds = new Set(receipt.matches.map((m) => m.chipId));
  const free = chips.filter((c) => !matchedIds.has(c.id) && c.state !== 'removed' && !c.dropped);
  const notOnReceipt = free;

  return (
    <section aria-label="Receipt">
      <ul className="receipt-list">
        {receipt.lines.map((line, i) => {
          const match = receipt.matches.find((m) => m.lineIndex === i);
          const chip = match ? chips.find((c) => c.id === match.chipId) : undefined;
          const mine = receipt.mine?.includes(i);
          const unmatched = receipt.unmatchedLines.includes(i) && !mine;
          return (
            <li key={i} className="card receipt-line">
              <div className="receipt-row">
                {chip?.photoUrl && (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img className="receipt-thumb" src={chip.photoUrl} alt="" />
                )}
                <span>{line.text}</span>
                <span>{formatCents(line.cents)}</span>
              </div>
              {match && chip && <span className="muted">{chip.name} · {Math.round(match.confidence * 100)}% sure</span>}
              {mine && <span className="muted">Mine</span>}
              {line.isTax && <span className="muted">Tax, spread across the lines</span>}
              {unmatched && canFix && (
                <div className="receipt-actions">
                  {pairing === i ? (
                    <select
                      disabled={busy}
                      aria-label={`Pair ${line.text} with`}
                      defaultValue=""
                      onChange={(e) => {
                        if (e.target.value) onFix(i, { chipId: e.target.value });
                        setPairing(null);
                      }}
                    >
                      <option value="" disabled>Choose a chip</option>
                      {free.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                    </select>
                  ) : (
                    <button type="button" className="btn btn-secondary" disabled={busy} onClick={() => setPairing(i)}>Pair…</button>
                  )}
                  <button type="button" className="btn btn-secondary" disabled={busy} onClick={() => onFix(i, 'mine')}>Mine</button>
                </div>
              )}
              {unmatched && !canFix && <span className="muted">Unmatched</span>}
            </li>
          );
        })}
      </ul>
      {notOnReceipt.length > 0 && (
        <p className="muted">Not on receipt: {notOnReceipt.map((c) => c.name).join(', ')}</p>
      )}
    </section>
  );
}
