'use client';
import { useDroppable } from '@dnd-kit/core';

/** Drop target over the live view; shown while any chip is lifted. */
export function RemoveZone() {
  const { setNodeRef, isOver } = useDroppable({ id: 'remove' });
  return (
    <div ref={setNodeRef} className={`remove-zone${isOver ? ' remove-zone-over' : ''}`} data-testid="remove-zone">
      Remove from cart
    </div>
  );
}
