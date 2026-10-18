'use client';
import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { useDndMonitor, useDraggable } from '@dnd-kit/core';
import type { Chip as ChipT, Person } from '@/lib/types';
import { Chip, isLiftable } from './Chip';

export type GridProps = {
  chips: ChipT[];
  me: string;
  people: Person[];
  /** Called when a chip is lifted (after the 200 ms hold). */
  onLift?: (chipId: string) => void;
  /** Non-drag fallback: Enter on a focused chip claims it. */
  onClaim?: (chipId: string) => void;
};

function GridChip({ chip, me, people, fresh, onClaim }: { chip: ChipT; me: string; people: Person[]; fresh: boolean; onClaim?: (id: string) => void }) {
  const liftable = isLiftable(chip);
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: chip.id,
    data: { chip, from: 'grid' },
    disabled: !liftable,
  });
  const onKeyDown = (e: KeyboardEvent<HTMLButtonElement>) => {
    if (e.key === 'Enter' && liftable) {
      e.preventDefault();
      onClaim?.(chip.id);
    }
  };
  return (
    <Chip
      ref={setNodeRef}
      chip={chip}
      me={me}
      people={people}
      fresh={fresh}
      className={isDragging ? 'chip-source' : undefined}
      {...(liftable ? listeners : {})}
      {...(liftable ? attributes : {})}
      onKeyDown={onKeyDown}
    />
  );
}

export function Grid({ chips, me, people, onLift, onClaim }: GridProps) {
  const ordered = useMemo(() => [...chips].sort((a, b) => b.addedAt - a.addedAt), [chips]);
  const seen = useRef<Set<string> | null>(null);
  const [fresh, setFresh] = useState<Set<string>>(new Set());
  const timers = useRef<Set<ReturnType<typeof setTimeout>>>(new Set());

  useEffect(() => {
    const ids = chips.map((c) => c.id);
    if (seen.current === null) {
      seen.current = new Set(ids);
      return;
    }
    const added = ids.filter((id) => !seen.current!.has(id));
    ids.forEach((id) => seen.current!.add(id));
    if (added.length === 0) return;
    setFresh((f) => new Set([...f, ...added]));
    const t = setTimeout(() => {
      timers.current.delete(t);
      setFresh((f) => new Set([...f].filter((id) => !added.includes(id))));
    }, 600);
    timers.current.add(t);
  }, [chips]);

  useEffect(() => {
    const all = timers.current;
    return () => all.forEach(clearTimeout);
  }, []);

  useDndMonitor({
    onDragStart(e) {
      if (e.active.data.current?.from === 'grid') {
        navigator.vibrate?.(10);
        onLift?.(String(e.active.id));
      }
    },
  });

  return (
    <div className="grid-scroll">
      <div className="grid" role="list">
        {ordered.map((chip) => (
          <div role="listitem" key={chip.id} className="grid-cell">
            <GridChip chip={chip} me={me} people={people} fresh={fresh.has(chip.id)} onClaim={onClaim} />
          </div>
        ))}
      </div>
    </div>
  );
}
