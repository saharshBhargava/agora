'use client';
import { useEffect, useState } from 'react';

/** One toast at a time; the owner replaces it by changing `key`. The Undo button counts down. */
export function UndoToast({
  label,
  onUndo,
  ms = 3000,
  onDismiss,
}: {
  label: string;
  onUndo: () => void;
  ms?: number;
  onDismiss?: () => void;
}) {
  const [left, setLeft] = useState(Math.ceil(ms / 1000));
  useEffect(() => {
    const t = setTimeout(() => onDismiss?.(), ms);
    const start = Date.now();
    const tick = setInterval(() => setLeft(Math.max(1, Math.ceil((ms - (Date.now() - start)) / 1000))), 250);
    return () => { clearTimeout(t); clearInterval(tick); };
  }, [ms, onDismiss]);

  return (
    <div className="toast" role="status">
      <span>{label}</span>
      <button type="button" className="toast-undo" aria-label="Undo" onClick={onUndo}>Undo · {left}s</button>
      <span className="toast-bar" style={{ animationDuration: `${ms}ms` }} aria-hidden="true" />
    </div>
  );
}
