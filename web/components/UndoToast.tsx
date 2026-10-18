'use client';
import { useEffect } from 'react';

/** One toast at a time; the owner replaces it by changing `key`. */
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
  useEffect(() => {
    const t = setTimeout(() => onDismiss?.(), ms);
    return () => clearTimeout(t);
  }, [ms, onDismiss]);

  return (
    <div className="toast" role="status">
      <span>{label}</span>
      <button type="button" className="toast-action" onClick={onUndo}>Undo</button>
      <span className="toast-bar" style={{ animationDuration: `${ms}ms` }} aria-hidden="true" />
    </div>
  );
}
