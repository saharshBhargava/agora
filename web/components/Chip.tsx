import { forwardRef, type ButtonHTMLAttributes, type CSSProperties } from 'react';
import type { Chip as ChipT, Person } from '@/lib/types';
import { formatCents } from '@/lib/money';
import { chipBorder, ringColor } from '@/lib/share';
import { tileColor } from '@/lib/tile';
import { Avatar } from './Avatar';

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

/** Accessible name shared by the shelf chip and the shopper's cart row. */
export function chipLabel(chip: ChipT, people: Person[]): string {
  const initialOf = (id: string) => people.find((p) => p.id === id)?.initial ?? '?';
  if (chip.state === 'wish') return `Wish: ${chip.name}, wished by ${initialOf(chip.wishedBy ?? '')}`;
  if (chip.state === 'identifying') return `${chip.name || 'Item'}, identifying`;
  const price = chip.priceCents === null ? 'price not known yet' : formatCents(chip.priceCents);
  const who = chip.claimers.map(initialOf);
  const claimed = who.length === 0 ? 'not claimed' : `claimed by ${who.length > 1 ? `${who.slice(0, -1).join(', ')} and ${who[who.length - 1]}` : who[0]}`;
  return `${chip.name}, ${price}, ${claimed}`;
}

/**
 * The small label at the chip's bottom right: "÷2" (in my blue) when I share it, "You" when it is only
 * mine, the claimer's name when one other person holds it, "open" when nobody does.
 */
export function chipTag(chip: ChipT, people: Person[], me: string): { text: string; color: string | null } {
  const n = chip.claimers.length;
  if (n === 0) return { text: 'open', color: null };
  const mine = chip.claimers.includes(me);
  if (n === 1) {
    const id = chip.claimers[0];
    return { text: mine ? 'You' : people.find((p) => p.id === id)?.name ?? '?', color: ringColor(people, id, me) };
  }
  return { text: `÷${n}`, color: mine ? ringColor(people, me, me) : 'var(--ink)' };
}

export const Chip = forwardRef<HTMLButtonElement, ChipProps>(function Chip(
  { chip, me, people, lifted, fresh, className, style, ...rest },
  ref,
) {
  const wish = chip.state === 'wish';
  const identifying = chip.state === 'identifying';
  const liftable = isLiftable(chip);
  const mine = chip.claimers.includes(me);
  const wisher = people.find((p) => p.id === chip.wishedBy);
  const shopper = people.find((p) => p.isShopper);

  const cls = ['chip', wish && 'chip-wish', identifying && 'chip-identifying', mine && 'chip-mine', lifted && 'chip-lifted', fresh && 'chip-new', className]
    .filter(Boolean)
    .join(' ');
  const border = wish
    ? (wisher ? ringColor(people, wisher.id, me) : 'var(--me)')
    : identifying ? 'var(--line)' : chipBorder(people, chip.claimers, me);
  const css = { '--chip-border': border, ...style } as CSSProperties;

  const common = {
    ref,
    type: 'button' as const,
    className: cls,
    style: css,
    'aria-label': chipLabel(chip, people),
    'data-liftable': liftable ? 'true' : 'false',
    'data-wish': wish ? '' : undefined,
    'data-identifying': identifying ? '' : undefined,
    'data-mine': mine ? '' : undefined,
    ...rest,
  };

  if (wish) {
    const myWish = !!wisher && wisher.id === me;
    const whose = myWish ? 'your' : `${wisher?.name ?? 'their'}'s`;
    return (
      <button {...common}>
        <span className="chip-photo">
          {wisher ? <Avatar person={wisher} people={people} me={me} size="sm" /> : <span className="chip-photo-fallback" aria-hidden="true">?</span>}
          <span className="chip-wish-who" style={{ color: border }}>{myWish ? 'Your wish' : `${wisher?.name ?? 'A'}'s wish`}</span>
        </span>
        <span className="chip-name">{chip.name}</span>
        <span className="chip-wish-note">Lands in {whose} tray when {shopper?.name ?? 'the shopper'} adds it</span>
      </button>
    );
  }

  const tag = identifying ? null : chipTag(chip, people, me);
  return (
    <button {...common}>
      <span className="chip-body">
        <span className="chip-photo" style={{ '--tile': tileColor(chip.id) } as CSSProperties}>
          {chip.photoUrl ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={chip.photoUrl} alt="" draggable={false} />
          ) : (
            <span className="chip-photo-fallback" aria-hidden="true">{chip.name.charAt(0)}</span>
          )}
          {chip.quantity > 1 && <span className="chip-badge chip-qty">×{chip.quantity}</span>}
          {chip.overCap.includes(me) && <span className="chip-badge chip-overcap">Over cap</span>}
        </span>
        <span className="chip-name">{chip.name || 'Identifying'}</span>
        <span className="chip-meta">
          <span className="chip-price">{identifying ? '…' : chip.priceCents === null ? '~$?' : formatCents(chip.priceCents)}</span>
          {tag && (
            <span className={`chip-tag${tag.color ? '' : ' chip-tag-open'}`} style={tag.color ? { color: tag.color } : undefined} aria-hidden="true">
              {tag.text}
            </span>
          )}
        </span>
      </span>
    </button>
  );
});
