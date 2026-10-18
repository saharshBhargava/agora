'use client';
import { useState } from 'react';
import type { Chip, ReceiptState } from '@/lib/types';
import { formatCents } from '@/lib/money';
import { isLiveChip } from '@/lib/share';

const plain = (cents: number) => formatCents(cents).replace('$', '');

/**
 * The receipt as mono lines with a TOTAL row. Before confirm each line shows its matched chip and
 * confidence; unmatched lines offer Pair… / Mine (shopper only). `compact` is the settled view.
 */
export function ReceiptMatch({
  receipt,
  chips,
  canFix,
  onFix,
  busy = false,
  compact = false,
}: {
  receipt: ReceiptState;
  chips: Chip[];
  canFix: boolean;
  busy?: boolean;
  compact?: boolean;
  onFix: (lineIndex: number, target: { chipId: string } | 'mine') => void;
}) {
  const [pairing, setPairing] = useState<number | null>(null);
  const matchedIds = new Set(receipt.matches.map((m) => m.chipId));
  // Live chips only: wishes, put-back, removed, dropped and still-identifying chips are never on a receipt.
  const free = chips.filter((c) => !matchedIds.has(c.id) && isLiveChip(c));
  const notOnReceipt = free;
  const items = receipt.lines.filter((l) => !l.isTax).length;
  const matched = receipt.lines.filter((l, i) => !l.isTax && receipt.matches.some((m) => m.lineIndex === i)).length;
  const total = receipt.lines.reduce((s, l) => s + l.cents, 0);

  return (
    <section className="card receipt-card" aria-label="Receipt">
      <div className="receipt-head">
        <h2>Receipt</h2>
        <span className="receipt-matched">{matched} of {items} lines matched</span>
      </div>
      <ul className="receipt-list">
        {receipt.lines.map((line, i) => {
          const match = receipt.matches.find((m) => m.lineIndex === i);
          const chip = match ? chips.find((c) => c.id === match.chipId) : undefined;
          const mine = receipt.mine?.includes(i);
          const unmatched = receipt.unmatchedLines.includes(i) && !mine;
          return (
            <li key={i} className="receipt-line">
              <div className="receipt-row">
                {!compact && chip?.photoUrl && (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img className="receipt-thumb" src={chip.photoUrl} alt="" />
                )}
                <span>{line.text}</span>
                <span>{plain(line.cents)}</span>
              </div>
              {!compact && match && chip && <span className="receipt-note">{chip.name} · {Math.round(match.confidence * 100)}% sure</span>}
              {mine && <span className="receipt-note">Mine</span>}
              {!compact && line.isTax && <span className="receipt-note">Tax, spread across the lines</span>}
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
                    <button type="button" className="btn btn-sm btn-secondary" disabled={busy} onClick={() => setPairing(i)}>Pair…</button>
                  )}
                  <button type="button" className="btn btn-sm btn-secondary" disabled={busy} onClick={() => onFix(i, 'mine')}>Mine</button>
                </div>
              )}
              {unmatched && !canFix && <span className="receipt-note">Unmatched</span>}
            </li>
          );
        })}
        <li className="receipt-row receipt-total"><span>TOTAL</span><span>{plain(total)}</span></li>
      </ul>
      {!compact && notOnReceipt.length > 0 && (
        <p className="receipt-note">Not on receipt: {notOnReceipt.map((c) => c.name).join(', ')}</p>
      )}
    </section>
  );
}
