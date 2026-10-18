'use client';
import { useEffect, useState } from 'react';
import type { Chip } from '@/lib/types';
import { formatCents } from '@/lib/money';
import { parseCents } from '@/lib/props';
import { QuantityStepper } from './QuantityStepper';

export type ChipFix = { name?: string; priceCents?: number; quantity?: number };

/** Name, price (of one) and count of a chip. Empty fields are left alone; only changes are sent. */
export function FixChipSheet({
  chip,
  onSave,
  onClose,
}: {
  chip: Chip;
  onSave: (fix: ChipFix) => void;
  onClose: () => void;
}) {
  const [name, setName] = useState(chip.name);
  const [quantity, setQuantity] = useState(chip.quantity);
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
          const fix: ChipFix = {};
          if (name.trim() && name.trim() !== chip.name) fix.name = name.trim();
          if (cents !== undefined && cents !== chip.priceCents) fix.priceCents = cents;
          if (quantity !== chip.quantity) fix.quantity = quantity;
          onSave(fix);
        }}
      >
        <h2>Fix this item</h2>
        <div className="field">
          <label htmlFor="fix-name">Name</label>
          <input id="fix-name" className="input" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
        </div>
        <div className="field-row">
          <div className="field">
            <label htmlFor="fix-price">{quantity > 1 ? 'Price each' : 'Price'}</label>
            <input id="fix-price" className="input" inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} placeholder="0.00" />
          </div>
          <div className="field field-qty">
            <span className="field-label">How many</span>
            <QuantityStepper name={chip.name || 'this item'} quantity={quantity} onChange={setQuantity} />
          </div>
        </div>
        {bad && <p className="error" role="alert">Enter a price like 4.29</p>}
        <button type="submit" className="btn" disabled={bad}>Save</button>
        <button type="button" className="btn btn-sm btn-ghost" onClick={onClose}>Cancel</button>
      </form>
    </div>
  );
}
