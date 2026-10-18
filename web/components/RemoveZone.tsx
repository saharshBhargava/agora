'use client';
import { useDroppable } from '@dnd-kit/core';

/** Drop target over the camera; shown while a row is lifted. The whole camera area accepts the drop. */
export function RemoveZone() {
  const { setNodeRef, isOver } = useDroppable({ id: 'remove' });
  return (
    <div ref={setNodeRef} className={`remove-zone${isOver ? ' remove-zone-over' : ''}`} data-testid="remove-zone">
      <span className="remove-zone-card">
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" strokeWidth="2" aria-hidden="true"><path d="M4 7h16M10 7V4h4v3M6 7l1 13h10l1-13" /></svg>
        <span>Drop here to remove from cart</span>
      </span>
    </div>
  );
}
