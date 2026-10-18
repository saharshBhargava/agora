'use client';
import { useEffect, useState } from 'react';
import type { WishPicks } from '@/lib/api';

/**
 * A claimer types an item, or taps one from the household list or the suggestions (past runs); it lands in the
 * grid as a wish chip.
 */
export function WishSheet({ onWish, busy, loadPicks }: {
  onWish: (name: string) => void | Promise<void>;
  busy: boolean;
  loadPicks?: () => Promise<WishPicks>;
}) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  const [picks, setPicks] = useState<WishPicks | null>(null);
  const [added, setAdded] = useState<string[]>([]);
  useEffect(() => {
    if (!open || !loadPicks) return;
    let live = true;
    loadPicks().then((p) => { if (live) setPicks(p); }).catch(() => { if (live) setPicks(null); });
    return () => { live = false; };
  }, [open, loadPicks]);
  if (!open) {
    return (
      <button type="button" className="btn btn-pill" onClick={() => setOpen(true)}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg>
        <span>Wish</span>
      </button>
    );
  }
  const pick = async (n: string) => {
    if (busy || added.includes(n)) return;
    await onWish(n);
    setAdded((a) => [...a, n]);
  };
  const listItems = picks?.list?.items ?? [];
  const suggestions = picks?.suggestions ?? [];
  return (
    <div className="wish-sheet-wrap">
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
        <button type="button" className="btn btn-sm btn-secondary" onClick={() => setOpen(false)}>Done</button>
      </form>
      {(listItems.length > 0 || suggestions.length > 0) && (
        <div className="wish-picks" aria-label="Wish suggestions">
          {listItems.length > 0 && <p className="wish-picks-title">{picks?.list?.name ?? 'Your shopping list'}</p>}
          {listItems.map((i) => (
            <button key={`l-${i.name}`} type="button" className="btn btn-sm btn-secondary wish-pick" disabled={busy || added.includes(i.name)} onClick={() => pick(i.name)}>
              {added.includes(i.name) ? '✓ ' : '+ '}{i.name}
            </button>
          ))}
          {suggestions.length > 0 && <p className="wish-picks-title">Suggested for you</p>}
          {suggestions.map((s) => (
            <button key={`s-${s.name}`} type="button" className="btn btn-sm btn-secondary wish-pick" title={s.reason} disabled={busy || added.includes(s.name)} onClick={() => pick(s.name)}>
              {added.includes(s.name) ? '✓ ' : '+ '}{s.name}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
