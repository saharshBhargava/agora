'use client';
import { useRef, useState } from 'react';
import {
  DndContext, DragOverlay, MeasuringStrategy, MouseSensor, TouchSensor, useSensor, useSensors,
} from '@dnd-kit/core';
import type { Chip as ChipT, Person } from '@/lib/types';
import { Chip } from './Chip';
import { Grid } from './Grid';
import { CartRows, CartRowView } from './CartRows';
import { RemoveZone } from './RemoveZone';
import { Tray, TrayChipView, type TrayApi, type TrayProps } from './Tray';

const HOLD = { delay: 200, tolerance: 5 };

/** Grid plus tray sharing one drag context: press-and-hold 200 ms lifts a chip, drop in the tray to claim. */
export type BoardExtras = {
  /** Shopper only: while a chip is lifted, a "Remove from cart" zone shows over the top of the screen. */
  removeZone?: boolean;
  /** Called when a chip is dropped on the remove zone. */
  onRemove?: (chipId: string) => void;
  /** A plain tap on a grid chip. */
  onTap?: (chipId: string) => void;
  /** 'shelf' (claimers: one scrolling row of chips plus the tray) or 'rows' (shopper: cart rows, no tray). */
  layout?: 'shelf' | 'rows';
  /** Rows only: the shopper's − N + stepper on each item row (a server call). */
  onQuantity?: (chipId: string, quantity: number) => Promise<unknown>;
};

export function Board({
  chips,
  people,
  removeZone,
  onRemove,
  onTap,
  layout = 'shelf',
  onQuantity,
  ...tray
}: { chips: ChipT[]; people: Person[] } & Omit<TrayProps, 'chips' | 'people'> & { trayChips?: ChipT[] } & BoardExtras) {
  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: HOLD }),
    useSensor(TouchSensor, { activationConstraint: HOLD }),
  );
  const [active, setActive] = useState<{ chip: ChipT; from: 'grid' | 'tray' } | null>(null);
  const trayApi = useRef<TrayApi>(null);
  const mine = tray.trayChips ?? chips.filter((c) => c.claimers.includes(tray.me) && c.state !== 'removed');
  const { trayChips: _t, ...trayProps } = tray;

  return (
    <DndContext
      id="dibs-board"
      sensors={sensors}
      measuring={{ droppable: { strategy: MeasuringStrategy.Always } }}
      onDragStart={(e) => setActive((e.active.data.current as { chip: ChipT; from: 'grid' | 'tray' }) ?? null)}
      onDragEnd={(e) => {
        const a = e.active.data.current as { chip?: ChipT } | undefined;
        if (removeZone && e.over?.id === 'remove' && a?.chip) onRemove?.(a.chip.id);
        setActive(null);
      }}
      onDragCancel={() => setActive(null)}
    >
      {removeZone && active && <RemoveZone />}
      {layout === 'rows' ? (
        <CartRows chips={chips} me={tray.me} people={people} onTap={onTap} onRemoveKey={onRemove} onQuantity={onQuantity} />
      ) : (
        <Grid
          onTap={onTap}
          chips={chips}
          me={tray.me}
          people={people}
          onClaim={(id) => {
            const c = chips.find((x) => x.id === id);
            if (c && !c.claimers.includes(tray.me)) trayApi.current?.claim(c);
          }}
        />
      )}
      {layout === 'shelf' && <Tray {...trayProps} chips={mine} people={people} apiRef={trayApi} />}
      <DragOverlay dropAnimation={{ duration: 180, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' }}>
        {active ? (
          active.from === 'tray' ? (
            <TrayChipView chip={active.chip} me={tray.me} people={people} className="chip-lifted chip-overlay" tabIndex={-1} />
          ) : layout === 'rows' ? (
            <CartRowView chip={active.chip} me={tray.me} people={people} className="chip-lifted chip-overlay" tabIndex={-1} />
          ) : (
            <Chip chip={active.chip} me={tray.me} people={people} lifted className="chip-overlay" tabIndex={-1} />
          )
        ) : null}
      </DragOverlay>
    </DndContext>
  );
}
