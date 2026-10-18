import { forwardRef, type ButtonHTMLAttributes } from 'react';
import type { Chip as ChipT, Person } from '@/lib/types';
import { formatCents } from '@/lib/money';
import { Ring } from './Ring';

export type ChipProps = {
  chip: ChipT;
  me: string;
  people: Person[];
  lifted?: boolean;
  fresh?: boolean;
} & Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'>;

export function isLiftable(chip: ChipT): boolean {
  return chip.state !== 'wish' && chip.state !== 'identifying';
}

function label(chip: ChipT, people: Person[]): string {
  const initialOf = (id: string) => people.find((p) => p.id === id)?.initial ?? '?';
  if (chip.state === 'wish') return `Wish: ${chip.name}, wished by ${initialOf(chip.wishedBy ?? '')}`;
  if (chip.state === 'identifying') return `${chip.name || 'Item'}, identifying`;
  const price = chip.priceCents === null ? 'price not known yet' : formatCents(chip.priceCents);
  const who = chip.claimers.map(initialOf);
  const claimed = who.length === 0 ? 'not claimed' : `claimed by ${who.length > 1 ? `${who.slice(0, -1).join(', ')} and ${who[who.length - 1]}` : who[0]}`;
  return `${chip.name}, ${price}, ${claimed}`;
}

export const Chip = forwardRef<HTMLButtonElement, ChipProps>(function Chip(
  { chip, me, people, lifted, fresh, className, ...rest },
  ref,
) {
  const wish = chip.state === 'wish';
  const identifying = chip.state === 'identifying';
  const liftable = isLiftable(chip);
  const mine = chip.claimers.includes(me);
  const claimers = chip.claimers
    .map((id) => people.find((p) => p.id === id))
    .filter((p): p is Person => !!p);
  const wisher = people.find((p) => p.id === chip.wishedBy);

  const cls = ['chip', wish && 'chip-wish', identifying && 'chip-identifying', mine && 'chip-mine', lifted && 'chip-lifted', fresh && 'chip-new', className]
    .filter(Boolean)
    .join(' ');

  return (
    <button
      ref={ref}
      type="button"
      className={cls}
      aria-label={label(chip, people)}
      data-liftable={liftable ? 'true' : 'false'}
      data-wish={wish ? '' : undefined}
      data-identifying={identifying ? '' : undefined}
      data-mine={mine ? '' : undefined}
      {...rest}
    >
      <span className="chip-photo">
        {chip.photoUrl && !wish ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={chip.photoUrl} alt="" draggable={false} />
        ) : (
          <span className="chip-photo-fallback" aria-hidden="true">{wish ? wisher?.initial ?? '?' : chip.name.charAt(0)}</span>
        )}
        {!wish && !identifying && (
          <span className="chip-ring"><Ring claimers={claimers} me={me} people={people} /></span>
        )}
        {chip.quantity > 1 && <span className="chip-badge chip-qty">×{chip.quantity}</span>}
        {chip.overCap.includes(me) && <span className="chip-badge chip-overcap">Over cap</span>}
      </span>
      <span className="chip-name">{chip.name || 'Identifying'}</span>
      {!wish && !identifying && (
        <span className="chip-price">{chip.priceCents === null ? '~$?' : formatCents(chip.priceCents)}</span>
      )}
      {wish && <span className="chip-price">wish</span>}
    </button>
  );
});
