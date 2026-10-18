'use client';
import { useState } from 'react';

/** A claimer types an item; it lands in the grid as a wish chip. */
export function WishSheet({ onWish, busy }: { onWish: (name: string) => void | Promise<void>; busy: boolean }) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  if (!open) {
    return (
      <button type="button" className="btn btn-pill" onClick={() => setOpen(true)}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg>
        <span>Wish</span>
      </button>
    );
  }
  return (
    <form
      className="wish-sheet"
      onSubmit={async (e) => {
        e.preventDefault();
        const n = name.trim();
        if (!n) return;
        await onWish(n);
        setName('');
        setOpen(false);
      }}
    >
      <input aria-label="Wish" placeholder="Bagels" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
      <button type="submit" className="btn btn-sm" disabled={busy || !name.trim()}>Add</button>
      <button type="button" className="btn btn-sm btn-secondary" onClick={() => setOpen(false)}>Cancel</button>
    </form>
  );
}
