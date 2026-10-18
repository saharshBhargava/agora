'use client';
import { forwardRef, type ButtonHTMLAttributes, type CSSProperties, type KeyboardEvent } from 'react';
import { useDndMonitor, useDraggable } from '@dnd-kit/core';
import type { Chip as ChipT, Person } from '@/lib/types';
import { formatCents } from '@/lib/money';
import { priceLabel, ringColor } from '@/lib/share';
import { tileColor } from '@/lib/tile';
import { Avatar, AvatarStack } from './Avatar';
import { chipLabel, isLiftable } from './Chip';
import { QuantityStepper } from './QuantityStepper';

type RowProps = { chip: ChipT; me: string; people: Person[] } & Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'>;

/** One cart line for the shopper: thumb, name, who is in, line total ("×2 · $1.10 each" under the name). Unclaimed lines are dashed. */
export const CartRowView = forwardRef<HTMLButtonElement, RowProps>(function CartRowView({ chip, me, people, className, style, ...rest }, ref) {
  const wish = chip.state === 'wish';
  const identifying = chip.state === 'identifying';
  const claimers = chip.claimers.map((id) => people.find((p) => p.id === id)).filter((p): p is Person => !!p);
  const wisher = people.find((p) => p.id === chip.wishedBy);
  const open = !wish && !identifying && claimers.length === 0;
  const wishColor = wisher ? ringColor(people, wisher.id, me) : 'var(--me)';
  const cls = ['cart-row', open && 'cart-row-open', wish && 'cart-row-wish', identifying && 'cart-row-identifying', className].filter(Boolean).join(' ');
  return (
    <button
      ref={ref}
      type="button"
      className={cls}
      style={{ '--tile': tileColor(chip.id), '--chip-border': wishColor, ...style } as CSSProperties}
      aria-label={chipLabel(chip, people)}
      data-liftable={isLiftable(chip) ? 'true' : 'false'}
      {...rest}
    >
      {wish && wisher ? (
        <Avatar person={wisher} people={people} me={me} size="lg" />
      ) : (
        <span className="cart-thumb" aria-hidden="true">
          {chip.photoUrl && !wish ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={chip.photoUrl} alt="" draggable={false} />
          ) : (chip.name.charAt(0) || '?')}
        </span>
      )}
      <span className="cart-row-text">
        <span className="cart-row-name">{chip.name || 'Identifying'}</span>
        {wish && <span className="cart-row-sub" style={{ color: wishColor }}>{wisher ? `${wisher.name} wants this` : 'Someone wants this'}</span>}
        {open && <span className="cart-row-sub">Nobody yet · stays yours</span>}
        {identifying && <span className="cart-row-sub">Identifying… tap to name it</span>}
        {chip.quantity > 1 && (
          <span className="cart-row-sub">×{chip.quantity}{chip.priceCents !== null ? ` · ${formatCents(chip.priceCents)} each` : ''}</span>
        )}
      </span>
      {claimers.length > 0 && <AvatarStack list={claimers} people={people} me={me} size="xs" />}
      {wish ? (
        <span className="cart-row-tag">wish</span>
      ) : (
        <span className="cart-row-price">{identifying ? '…' : priceLabel(chip)}</span>
      )}
    </button>
  );
});

function CartRow({ chip, me, people, onTap, onRemoveKey }: { chip: ChipT; me: string; people: Person[]; onTap?: (id: string) => void; onRemoveKey?: (id: string) => void }) {
  const liftable = isLiftable(chip);
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({ id: chip.id, data: { chip, from: 'grid' }, disabled: !liftable });
  const onKeyDown = (e: KeyboardEvent<HTMLButtonElement>) => {
    // Keyboard stand-in for dragging a row onto "Remove from cart".
    if ((e.key === 'Delete' || e.key === 'Backspace') && liftable) {
      e.preventDefault();
      onRemoveKey?.(chip.id);
    }
  };
  return (
    <CartRowView
      ref={setNodeRef}
      chip={chip}
      me={me}
      people={people}
      className={isDragging ? 'chip-source' : undefined}
      {...(liftable ? listeners : {})}
      {...(liftable ? attributes : {})}
      onKeyDown={onKeyDown}
      onClick={onTap ? () => onTap(chip.id) : undefined}
    />
  );
}

/**
 * The shopper's cart as rows. Hold a row to lift it (the remove zone appears); tap to fix it. With
 * `onQuantity`, every item row (not wishes) has a − N + stepper beside it, outside the row's own button.
 */
export function CartRows({ chips, me, people, onTap, onRemoveKey, onQuantity }: {
  chips: ChipT[];
  me: string;
  people: Person[];
  onTap?: (id: string) => void;
  onRemoveKey?: (id: string) => void;
  onQuantity?: (id: string, quantity: number) => Promise<unknown>;
}) {
  const ordered = [...chips].sort((a, b) => Number(b.state === 'wish') - Number(a.state === 'wish') || b.addedAt - a.addedAt);
  useDndMonitor({ onDragStart() { navigator.vibrate?.(10); } });
  if (ordered.length === 0) return <p className="cart-empty">Nothing in the cart yet.</p>;
  return (
    <ul className="cart-rows" aria-label="In the cart">
      {ordered.map((c) => {
        const adjustable = !!onQuantity && isLiftable(c);
        return (
          <li key={c.id} className={adjustable ? 'cart-row-item cart-row-item-qty' : 'cart-row-item'}>
            <CartRow chip={c} me={me} people={people} onTap={onTap} onRemoveKey={onRemoveKey} />
            {adjustable && <QuantityStepper name={c.name} quantity={c.quantity} onChange={(q) => onQuantity(c.id, q)} />}
          </li>
        );
      })}
    </ul>
  );
}
