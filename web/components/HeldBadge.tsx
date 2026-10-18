import { formatCents } from '@/lib/money';

export function HeldBadge({ cents, approvalCode }: { cents: number; approvalCode?: string | null }) {
  return (
    <span className="badge badge-held">
      {formatCents(cents)} held{approvalCode ? ` · approval ${approvalCode}` : ''}
    </span>
  );
}
