/** Integer cents to display dollars. No floats are used for arithmetic. */
export function formatCents(cents: number): string {
  const sign = cents < 0 ? '-' : '';
  const abs = Math.abs(cents);
  return `${sign}$${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`;
}

/** "$40" for whole dollars, "$40.50" otherwise: for hero numbers and buttons. */
export function wholeCents(cents: number): string {
  return cents % 100 === 0 ? `${cents < 0 ? '-' : ''}$${Math.abs(cents) / 100}` : formatCents(cents);
}
