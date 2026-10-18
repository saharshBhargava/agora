'use client';
import { useState } from 'react';
import type { Chip, Person, ReceiptState } from '@/lib/types';
import { formatCents } from '@/lib/money';
import { isLiveChip, listNames, nameWithQty, pairableChips } from '@/lib/share';
import { tileColor } from '@/lib/tile';

const plain = (cents: number) => formatCents(cents).replace('$', '');

/** Lines matched to a chip, and lines that still need the shopper (unmatched and not marked Mine). */
export function receiptCounts(receipt: ReceiptState): { matched: number; items: number; needs: number } {
  const items = receipt.lines.filter((l) => !l.isTax).length;
  const matched = receipt.lines.filter((l, i) => !l.isTax && receipt.matches.some((m) => m.lineIndex === i)).length;
  const needs = receipt.unmatchedLines.filter((i) => !receipt.mine?.includes(i)).length;
  return { matched, items, needs };
}

/**
 * Before confirm ("check"): one row per receipt line with its matched item, who is in and the match
 * confidence; an unmatched line is an orange card asking whose it is (Pair with an item / Mine, shopper
 * only). `compact` is the settled view: a mono receipt card with a TOTAL row.
 */
export function ReceiptMatch({
  receipt,
  chips,
  canFix,
  onFix,
  busy = false,
  compact = false,
  people = [],
}: {
  receipt: ReceiptState;
  chips: Chip[];
  canFix: boolean;
  busy?: boolean;
  compact?: boolean;
  people?: Person[];
  onFix: (lineIndex: number, target: { chipId: string } | 'mine') => void;
}) {
  const [pairing, setPairing] = useState<number | null>(null);
  const matchedIds = new Set(receipt.matches.map((m) => m.chipId));
  // Live chips only: wishes, put-back, removed, dropped and still-identifying chips are never on a receipt.
  const notOnReceipt = chips.filter((c) => !matchedIds.has(c.id) && isLiveChip(c));
  // A line can also go to a chip counted more than once whose lines so far cover fewer items.
  const free = pairableChips(receipt, chips);
  const { matched, items } = receiptCounts(receipt);
  const total = receipt.lines.reduce((s, l) => s + l.cents, 0);
  const nameOf = (id: string) => people.find((p) => p.id === id)?.name ?? '?';

  const actions = (i: number, text: string) => (
    <div className="receipt-actions">
      {pairing === i ? (
        <select
          disabled={busy}
          aria-label={`Pair ${text} with`}
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
        <button type="button" className="btn btn-sm btn-outline" disabled={busy} onClick={() => setPairing(i)}>Pair with an item</button>
      )}
      <button type="button" className="btn btn-sm" disabled={busy} onClick={() => onFix(i, 'mine')}>Mine</button>
    </div>
  );

  if (!compact) {
    return (
      <section aria-label="Receipt">
        <ul className="check-list">
          {receipt.lines.map((line, i) => {
            const match = receipt.matches.find((m) => m.lineIndex === i);
            const chip = match ? chips.find((c) => c.id === match.chipId) : undefined;
            const mine = receipt.mine?.includes(i);
            const unmatched = receipt.unmatchedLines.includes(i) && !mine && !line.isTax;
            const who = chip ? (chip.claimers.length ? listNames(chip.claimers.map(nameOf)) : 'yours') : null;
            return (
              <li key={i} className={`check-row${unmatched ? ' check-row-open' : ''}`}>
                <div className="check-main">
                  {!unmatched && (
                    <span className="check-thumb" style={{ '--tile': chip ? tileColor(chip.id) : 'var(--surface-2)' } as React.CSSProperties} aria-hidden="true">
                      {chip?.photoUrl && (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img src={chip.photoUrl} alt="" />
                      )}
                    </span>
                  )}
                  <span className="check-text">
                    <span className="mono check-line">{line.text}</span>
                    {chip && <span className="check-sub">{nameWithQty(chip)} · {who}</span>}
                    {mine && <span className="check-sub">Mine</span>}
                    {line.isTax && <span className="check-sub">Tax, spread across the lines</span>}
                    {unmatched && <span className="check-ask">{canFix ? 'Not in the cart. Whose is it?' : 'Unmatched'}</span>}
                  </span>
                  <span className="check-side">
                    <strong>{formatCents(line.cents)}</strong>
                    {match && <span className="check-conf">{Math.round(match.confidence * 100)}% match</span>}
                  </span>
                </div>
                {unmatched && canFix && actions(i, line.text)}
              </li>
            );
          })}
        </ul>
        {notOnReceipt.length > 0 && (
          <p className="receipt-note">Not on receipt: {notOnReceipt.map((c) => c.name).join(', ')}</p>
        )}
      </section>
    );
  }

  return (
    <section className="card receipt-card" aria-label="Receipt">
      <div className="receipt-head">
        <h2>Receipt</h2>
        <span className="receipt-matched">{matched} of {items} lines matched</span>
      </div>
      <ul className="receipt-list">
        {receipt.lines.map((line, i) => {
          const mine = receipt.mine?.includes(i);
          return (
            <li key={i} className="receipt-line">
              <div className="receipt-row">
                <span>{line.text}</span>
                <span>{plain(line.cents)}</span>
              </div>
              {mine && <span className="receipt-note">Mine</span>}
            </li>
          );
        })}
        <li className="receipt-row receipt-total"><span>TOTAL</span><span>{plain(total)}</span></li>
      </ul>
    </section>
  );
}
