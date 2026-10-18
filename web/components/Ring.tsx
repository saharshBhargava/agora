import type { Person } from '@/lib/types';
import { ringColor } from '@/lib/share';

const SIZE = 48;
const R = 18;
const C = 2 * Math.PI * R;
const THIN = 8;
const THICK = 12;

/** Who is in on a chip. One claimer: a full ring with an open notch (never reads as "taken"). */
export function Ring({ claimers, me, people }: { claimers: Person[]; me: string; people: Person[] }) {
  const n = claimers.length;
  if (n === 0) return null;
  const mid = SIZE / 2;
  const title = claimers.map((c) => c.name).join(', ');

  return (
    <svg className="ring" viewBox={`0 0 ${SIZE} ${SIZE}`} width={SIZE} height={SIZE} role="img" aria-label={`In: ${title}`}>
      <title>{title}</title>
      <circle cx={mid} cy={mid} r={SIZE / 2 - 1} fill="var(--surface)" />
      {n === 1 && (
        <>
          <circle
            data-notch
            cx={mid}
            cy={mid}
            r={R}
            fill="none"
            stroke={ringColor(people, claimers[0].id, me)}
            strokeWidth={claimers[0].id === me ? THICK : THIN}
            strokeLinecap="round"
            strokeDasharray={`${C * 0.84} ${C * 0.16}`}
            transform={`rotate(-70 ${mid} ${mid})`}
          />
          <text x={mid} y={mid} className="ring-initial" fill="var(--text)">{claimers[0].initial}</text>
        </>
      )}
      {n >= 2 && n <= 3 &&
        claimers.map((c, i) => {
          const start = (360 / n) * i - 90;
          const len = C / n - 5;
          const midAngle = ((start + 360 / n / 2) * Math.PI) / 180;
          const isMe = c.id === me;
          return (
            <g key={c.id}>
              <circle
                data-segment
                cx={mid}
                cy={mid}
                r={R}
                fill="none"
                stroke={ringColor(people, c.id, me)}
                strokeWidth={isMe ? THICK : THIN}
                strokeDasharray={`${len} ${C - len}`}
                transform={`rotate(${start + 1.5} ${mid} ${mid})`}
              />
              <text
                x={mid + R * Math.cos(midAngle)}
                y={mid + R * Math.sin(midAngle)}
                className="ring-initial ring-initial-seg"
                fill="#fff"
              >
                {c.initial}
              </text>
            </g>
          );
        })}
      {n >= 4 && (
        <>
          <circle cx={mid} cy={mid} r={R} fill="none" stroke="var(--text-muted)" strokeWidth={THIN} />
          <text x={mid} y={mid} className="ring-initial ring-count" fill="var(--text)">{n}</text>
        </>
      )}
    </svg>
  );
}
