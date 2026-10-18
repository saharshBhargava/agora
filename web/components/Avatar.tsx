import type { Person } from '@/lib/types';
import { ringColor } from '@/lib/share';

type Size = 'xs' | 'sm' | 'md' | 'lg';

/** One round initial in the person's color. */
export function Avatar({ person, people, me, size = 'md', dashed }: { person: Person; people: Person[]; me: string; size?: Size; dashed?: boolean }) {
  return (
    <span
      className={`avatar${size === 'md' ? '' : ` avatar-${size}`}${dashed ? ' avatar-dashed' : ''}`}
      style={{ background: ringColor(people, person.id, me) }}
      title={person.name}
      aria-hidden="true"
    >
      {person.initial}
    </span>
  );
}

/** Overlapping initials. `label` names the group for screen readers. */
export function AvatarStack({ list, people, me, size = 'md', label, extra }: { list: Person[]; people: Person[]; me: string; size?: Size; label?: string; extra?: React.ReactNode }) {
  return (
    <span className={`avatars${size === 'md' ? '' : ` avatars-${size}`}`} role={label ? 'img' : undefined} aria-label={label}>
      {list.map((p) => <Avatar key={p.id} person={p} people={people} me={me} size={size} />)}
      {extra}
    </span>
  );
}
