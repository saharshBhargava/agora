import { fireEvent, render, screen } from '@testing-library/react';
import { expect, test, vi } from 'vitest';
import { ReceiptMatch } from '@/components/ReceiptMatch';
import type { Chip, ReceiptState } from '@/lib/types';

const chip = (id: string, name: string, o: Partial<Chip> = {}): Chip => ({
  id, name, priceCents: 100, priceSource: 'sticker', photoUrl: null, region: null, quantity: 1,
  claimers: [], state: 'unmatched', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
  overCap: [], removedAt: null, addedAt: 0, ...o,
});

test('pairing and Not on receipt list live chips only', () => {
  const receipt: ReceiptState = {
    lines: [{ text: 'BUTTER', cents: 599, quantity: 1, isTax: false }],
    matches: [],
    unmatchedLines: [0],
  };
  const chips = [
    chip('jam', 'Jam'),
    chip('w', 'Bagels', { state: 'wish' }),
    chip('pb', 'Milk', { putBack: true }),
    chip('rm', 'Soap', { state: 'removed' }),
    chip('dr', 'Mystery', { state: 'identifying', dropped: true }),
  ];
  render(<ReceiptMatch receipt={receipt} chips={chips} canFix onFix={vi.fn()} />);
  expect(screen.getByText('Not on receipt: Jam')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Pair…' }));
  const options = screen.getAllByRole('option').map((o) => o.textContent);
  expect(options).toEqual(['Choose a chip', 'Jam']);
});
