'use client';
import { useState } from 'react';

/** A claimer types an item; it lands in the grid as a wish chip. */
export function WishSheet({ onWish, busy }: { onWish: (name: string) => void | Promise<void>; busy: boolean }) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  if (!open) {
    return <button type="button" className="btn btn-secondary" onClick={() => setOpen(true)}>Wish</button>;
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
      <button type="submit" className="btn" disabled={busy || !name.trim()}>Add</button>
      <button type="button" className="btn btn-secondary" onClick={() => setOpen(false)}>Cancel</button>
    </form>
  );
}
