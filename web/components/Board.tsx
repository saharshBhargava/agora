'use client';
import { useState } from 'react';
import {
  DndContext, DragOverlay, MeasuringStrategy, PointerSensor, TouchSensor, useSensor, useSensors,
} from '@dnd-kit/core';
import type { Chip as ChipT, Person } from '@/lib/types';
import { Chip } from './Chip';
import { Grid } from './Grid';
import { Tray, type TrayProps } from './Tray';

const HOLD = { delay: 200, tolerance: 5 };

/** Grid plus tray sharing one drag context: press-and-hold 200 ms lifts a chip, drop in the tray to claim. */
export function Board({
  chips,
  people,
  ...tray
}: { chips: ChipT[]; people: Person[] } & Omit<TrayProps, 'chips' | 'people'> & { trayChips?: ChipT[] }) {
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: HOLD }),
    useSensor(TouchSensor, { activationConstraint: HOLD }),
  );
  const [active, setActive] = useState<ChipT | null>(null);
  const mine = tray.trayChips ?? chips.filter((c) => c.claimers.includes(tray.me) && c.state !== 'removed');
  const { trayChips: _t, ...trayProps } = tray;

  return (
    <DndContext
      id="dibs-board"
      sensors={sensors}
      measuring={{ droppable: { strategy: MeasuringStrategy.Always } }}
      onDragStart={(e) => setActive((e.active.data.current?.chip as ChipT) ?? null)}
      onDragEnd={() => setActive(null)}
      onDragCancel={() => setActive(null)}
    >
      <Grid
        chips={chips}
        me={tray.me}
        people={people}
        onClaim={(id) => {
          const c = chips.find((x) => x.id === id);
          if (c && !c.claimers.includes(tray.me)) tray.onClaim(id);
        }}
      />
      <Tray {...trayProps} chips={mine} people={people} />
      <DragOverlay dropAnimation={{ duration: 180, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' }}>
        {active ? <Chip chip={active} me={tray.me} people={people} lifted tabIndex={-1} /> : null}
      </DragOverlay>
    </DndContext>
  );
}
