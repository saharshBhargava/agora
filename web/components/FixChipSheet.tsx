'use client';
import { useEffect, useState } from 'react';
import type { Chip } from '@/lib/types';
import { formatCents } from '@/lib/money';
import { parseCents } from '@/lib/props';

/** Name and price a chip. Empty fields are left alone. */
export function FixChipSheet({
  chip,
  onSave,
  onClose,
}: {
  chip: Chip;
  onSave: (fix: { name?: string; priceCents?: number }) => void;
  onClose: () => void;
}) {
  const [name, setName] = useState(chip.name);
  const [price, setPrice] = useState(chip.priceCents === null ? '' : formatCents(chip.priceCents).replace('$', ''));
  useEffect(() => {
    const on = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  }, [onClose]);
  const cents = price.trim() === '' ? undefined : parseCents(price);
  const bad = cents === null;

  return (
    <div className="sheet-backdrop" onClick={onClose}>
      <form
        className="sheet"
        role="dialog"
        aria-label="Fix chip"
        onClick={(e) => e.stopPropagation()}
        onSubmit={(e) => {
          e.preventDefault();
          if (bad) return;
          const fix: { name?: string; priceCents?: number } = {};
          if (name.trim() && name.trim() !== chip.name) fix.name = name.trim();
          if (cents !== undefined && cents !== chip.priceCents) fix.priceCents = cents;
          onSave(fix);
        }}
      >
        <h2>Name it</h2>
        <div className="field">
          <label htmlFor="fix-name">Name</label>
          <input id="fix-name" className="input" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
        </div>
        <div className="field">
          <label htmlFor="fix-price">Price</label>
          <input id="fix-price" className="input" inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} placeholder="0.00" />
        </div>
        {bad && <p className="error" role="alert">Enter a price like 4.29</p>}
        <div className="sheet-row">
          <button type="button" className="btn btn-secondary" onClick={onClose}>Cancel</button>
          <button type="submit" className="btn" disabled={bad}>Save</button>
        </div>
      </form>
    </div>
  );
}
