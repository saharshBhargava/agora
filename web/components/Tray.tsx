'use client';
import { forwardRef, useCallback, useImperativeHandle, useState, type KeyboardEvent, type Ref } from 'react';
import { useDndMonitor, useDraggable, useDroppable, type Active } from '@dnd-kit/core';
import type { Chip as ChipT, Person } from '@/lib/types';
import { formatCents } from '@/lib/money';
import { myShare, roomFor } from '@/lib/share';
import { UndoToast } from './UndoToast';

export type TrayProps = {
  /** My tray chips. */
  chips: ChipT[];
  me: string;
  people: Person[];
  /** null for the shopper: no hold, no cap check. */
  authorizedCents: number | null;
  taxRate: number;
  /** Force the expanded state; it also expands on its own while a chip is lifted. */
  expanded?: boolean;
  onClaim: (chipId: string) => void;
  onLeave: (chipId: string) => void;
  /** A claim that would exceed room springs back and calls this ("Over your cap. Raise it?"). */
  onOverCap?: (chip: ChipT) => void;
  /** Imperative claim/leave through the same path as a drop (room check, undo toast). */
  apiRef?: Ref<TrayApi>;
};

export type TrayApi = { claim: (chip: ChipT) => void; leave: (chip: ChipT) => void };

type Toast = { key: number; label: string; undo: () => void };
type Lifted = { chip: ChipT; from: 'grid' | 'tray' };

function liftedOf(active: Active): Lifted | null {
  const d = active.data.current as { chip?: ChipT; from?: 'grid' | 'tray' } | undefined;
  return d?.chip && d.from ? { chip: d.chip, from: d.from } : null;
}

export const TrayChipView = forwardRef<HTMLButtonElement, { chip: ChipT; me: string } & React.ButtonHTMLAttributes<HTMLButtonElement>>(function TrayChipView({ chip, me, className, ...rest }, ref) {
  const n = chip.claimers.length;
  const share = chip.priceCents === null ? null : myShare(chip.priceCents, chip.claimers, me);
  return (
    <button
      ref={ref}
      type="button"
      className={`tray-chip${className ? ` ${className}` : ''}`}
      aria-label={`${chip.name}, your share ${share === null ? 'not known yet' : formatCents(share)}${n > 1 ? `, split ${n} ways` : ''}`}
      {...rest}
    >
      <span className="tray-chip-share">{share === null ? '~$?' : formatCents(share)}</span>
      {n > 1 && <span className="chip-badge tray-split">÷{n}</span>}
      <span className="tray-chip-name">{chip.name}</span>
    </button>
  );
});

function TrayChip({ chip, me, onLeave }: { chip: ChipT; me: string; onLeave: (chip: ChipT) => void }) {
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: `tray:${chip.id}`,
    data: { chip, from: 'tray' },
  });
  const onKeyDown = (e: KeyboardEvent<HTMLButtonElement>) => {
    if (e.key === 'Enter' || e.key === 'Delete' || e.key === 'Backspace') {
      e.preventDefault();
      onLeave(chip);
    }
  };
  return (
    <TrayChipView
      ref={setNodeRef}
      chip={chip}
      me={me}
      className={isDragging ? 'chip-source' : undefined}
      {...listeners}
      {...attributes}
      onKeyDown={onKeyDown}
    />
  );
}

export function Tray({ chips, me, people: _people, authorizedCents, taxRate, expanded, onClaim, onLeave, onOverCap, apiRef }: TrayProps) {
  const [lifted, setLifted] = useState<Lifted | null>(null);
  const [toast, setToast] = useState<Toast | null>(null);
  const { setNodeRef, isOver } = useDroppable({ id: 'tray' });
  const dismiss = useCallback(() => setToast(null), []);

  const inTray = (id: string) => chips.some((c) => c.id === id);
  // Live preview: what the tray would be if the lifted grid chip were dropped here.
  const preview =
    lifted && lifted.from === 'grid' && !inTray(lifted.chip.id)
      ? [...chips, { ...lifted.chip, claimers: [...lifted.chip.claimers, me] }]
      : chips;
  const shareOf = (c: ChipT) => myShare(c.priceCents, c.claimers, me);
  const totalShare = preview.reduce((s, c) => s + shareOf(c), 0);
  const room = authorizedCents === null ? null : roomFor(preview.map((c) => c.priceCents ?? 0), authorizedCents, taxRate);
  const overCapPreview = room !== null && room < 0;
  const isExpanded = !!expanded || lifted !== null;

  const show = (label: string, undo: () => void) => setToast({ key: Date.now(), label, undo });

  const claim = (chip: ChipT) => {
    if (inTray(chip.id)) return;
    if (authorizedCents !== null) {
      const after = roomFor([...chips, chip].map((c) => c.priceCents ?? 0), authorizedCents, taxRate);
      if (after < 0) {
        onOverCap?.(chip);
        return;
      }
    }
    onClaim(chip.id);
    show(`Claimed ${chip.name}`, () => { onLeave(chip.id); setToast(null); });
  };
  const leave = (chip: ChipT) => {
    onLeave(chip.id);
    show(`Left ${chip.name}`, () => { onClaim(chip.id); setToast(null); });
  };
  useImperativeHandle(apiRef, () => ({ claim, leave }));

  useDndMonitor({
    onDragStart(e) {
      setLifted(liftedOf(e.active));
    },
    onDragCancel() {
      setLifted(null);
    },
    onDragEnd(e) {
      setLifted(null);
      const l = liftedOf(e.active);
      if (!l) return;
      const inside = e.over?.id === 'tray';
      if (l.from === 'grid' && inside) claim(l.chip);
      else if (l.from === 'tray' && !inside && e.over?.id !== 'remove') leave(l.chip);
    },
  });

  const summary = `${chips.length} ${chips.length === 1 ? 'item' : 'items'} · ${formatCents(totalShare)}`;

  return (
    <>
      {toast && <UndoToast key={toast.key} label={toast.label} onUndo={toast.undo} onDismiss={dismiss} />}
      <section
        ref={setNodeRef}
        className={`tray${isExpanded ? ' tray-expanded' : ''}${isOver ? ' tray-over' : ''}`}
        data-expanded={isExpanded ? 'true' : 'false'}
        aria-label="Your tray"
      >
        <div className="tray-handle" aria-hidden="true" />
        {authorizedCents !== null && (
          <p className={`tray-header${overCapPreview ? ' tray-header-over' : ''}`}>
            {`${formatCents(authorizedCents)} held · ${formatCents(totalShare)} your share · ${formatCents(room ?? 0)} room`}
          </p>
        )}
        <p className="tray-summary">{summary}</p>
        {overCapPreview && <p className="tray-warn">Over your cap. Raise it?</p>}
        <div className="tray-chips">
          {chips.map((c) => <TrayChip key={c.id} chip={c} me={me} onLeave={leave} />)}
          {chips.length === 0 && <p className="muted tray-empty">Lift a chip and drop it here to claim it.</p>}
        </div>
      </section>
    </>
  );
}
