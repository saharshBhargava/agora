import { act, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test, vi } from 'vitest';
import type { Chip as ChipT, Person, ReceiptState } from '@/lib/types';
import {
  coverage, lineCents, MAX_QUANTITY, nameWithQty, pairableChips, priceLabel, qtyText, stepQuantity,
} from '@/lib/share';
import { Chip } from '@/components/Chip';
import { CartRowView } from '@/components/CartRows';
import { FixChipSheet } from '@/components/FixChipSheet';
import { QuantityStepper } from '@/components/QuantityStepper';
import { TrayChipView } from '@/components/Tray';
import { UnclaimedList } from '@/components/UnclaimedList';
import { ReceiptMatch } from '@/components/ReceiptMatch';
import { staysWith } from '@/app/settle/SettleScreen';

const p = (id: string, name: string, isShopper = false): Person => ({
  id, name, initial: name[0], isShopper, authorizedCents: isShopper ? null : 4000, authId: null, approvalCode: null, payoutPan: null,
});
const people = [p('s', 'Jake', true), p('a', 'Priya'), p('b', 'Marcus')];
const mk = (o: Partial<ChipT> = {}): ChipT => ({
  id: 'apple', name: 'Cosmic Crisp Apple', priceCents: 110, priceSource: 'web', photoUrl: null, region: null, quantity: 2,
  claimers: [], state: 'open', wishedBy: null, duplicateOf: null, putBack: false, dropped: false,
  overCap: [], removedAt: null, addedAt: 0, ...o,
});

afterEach(() => vi.useRealTimers());

test('lineCents is unit times quantity, or the receipt total; null while unpriced', () => {
  expect(lineCents(mk())).toBe(220);
  expect(lineCents(mk({ quantity: 1 }))).toBe(110);
  expect(lineCents(mk({ receiptTotalCents: 219 }))).toBe(219);
  expect(lineCents(mk({ priceCents: null }))).toBeNull();
});

test('×N only above one; the name and price labels carry it', () => {
  expect(qtyText(1)).toBe('');
  expect(qtyText(2)).toBe('×2');
  expect(nameWithQty(mk())).toBe('Cosmic Crisp Apple ×2');
  expect(nameWithQty(mk({ quantity: 1 }))).toBe('Cosmic Crisp Apple');
  expect(priceLabel(mk())).toBe('$2.20');
  expect(priceLabel(mk({ priceCents: null }))).toBe('~$?');
});

test('the stepper stays within 1 to 20', () => {
  expect(MAX_QUANTITY).toBe(20);
  expect(stepQuantity(1, -1)).toBeNull();
  expect(stepQuantity(1, 1)).toBe(2);
  expect(stepQuantity(20, 1)).toBeNull();
  expect(stepQuantity(20, -1)).toBe(19);
});

test('coverage counts line totals', () => {
  const r = coverage(people, [mk({ claimers: ['a', 'b', 's'] })]);
  expect(r).toEqual({
    coveredCents: 147, totalCents: 220,
    segments: [{ id: 'a', name: 'Priya', cents: 74 }, { id: 'b', name: 'Marcus', cents: 73 }],
  });
});

test('a claimer chip shows ×2 and the line total', () => {
  render(<Chip chip={mk()} me="a" people={people} />);
  expect(screen.getByText('×2')).toBeTruthy();
  expect(screen.getByText('$2.20')).toBeTruthy();
  expect(screen.getByLabelText('Cosmic Crisp Apple ×2, $2.20, not claimed')).toBeTruthy();
});

test('a tray chip shows ×2 and my split of the line total', () => {
  render(<TrayChipView chip={mk({ claimers: ['a', 'b'], state: 'claimed' })} me="a" people={people} />);
  expect(screen.getByText('Cosmic Crisp Apple ×2')).toBeTruthy();
  expect(screen.getByText('$1.10')).toBeTruthy();
  expect(screen.getByLabelText('Cosmic Crisp Apple ×2, your share $1.10, split 2 ways')).toBeTruthy();
});

test('a shopper row shows the line total and the unit price under the name', () => {
  render(<CartRowView chip={mk()} me="s" people={people} />);
  expect(screen.getByText('$2.20')).toBeTruthy();
  expect(screen.getByText('×2 · $1.10 each')).toBeTruthy();
});

test('QuantityStepper: − is disabled at 1, + at 20, and a tap sends the next count', async () => {
  const onChange = vi.fn(async () => undefined);
  const { rerender } = render(<QuantityStepper name="Cosmic Crisp Apple" quantity={1} onChange={onChange} />);
  expect(screen.getByRole('button', { name: 'One fewer Cosmic Crisp Apple' })).toBeDisabled();
  expect(screen.getByText('1')).toBeTruthy();
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'One more Cosmic Crisp Apple' })); });
  expect(onChange).toHaveBeenCalledWith(2);
  rerender(<QuantityStepper name="Cosmic Crisp Apple" quantity={20} onChange={onChange} />);
  expect(screen.getByRole('button', { name: 'One more Cosmic Crisp Apple' })).toBeDisabled();
  expect(screen.getByRole('button', { name: 'One fewer Cosmic Crisp Apple' })).not.toBeDisabled();
});

test('QuantityStepper shows the new count at once and goes back to the server count when the call fails', async () => {
  let reject: (e: Error) => void = () => undefined;
  const onChange = vi.fn(() => new Promise<void>((_, r) => { reject = r; }));
  render(<QuantityStepper name="Apple" quantity={2} onChange={onChange} />);
  fireEvent.click(screen.getByRole('button', { name: 'One more Apple' }));
  expect(screen.getByText('3')).toBeTruthy();
  // One call at a time, so a quick second tap never races the first.
  expect(screen.getByRole('button', { name: 'One more Apple' })).toBeDisabled();
  await act(async () => { reject(new Error('cart closed')); });
  expect(screen.getByText('2')).toBeTruthy();
});

test('the fix sheet has the stepper; Save sends a changed quantity', () => {
  const onSave = vi.fn();
  render(<FixChipSheet chip={mk()} onSave={onSave} onClose={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'One more Cosmic Crisp Apple' }));
  expect(screen.getByText('3')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  expect(onSave).toHaveBeenCalledWith({ quantity: 3 });
});

test('the fix sheet sends no quantity when it did not change', () => {
  const onSave = vi.fn();
  render(<FixChipSheet chip={mk()} onSave={onSave} onClose={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  expect(onSave).toHaveBeenCalledWith({});
});

test('the unclaimed list shows ×2 and the line total', () => {
  const run = {
    id: 'r', state: 'locked' as const, store: 'QFC', shopperId: 's', people, chips: [mk({ state: 'locked' })], taxRate: 0,
    lastCallEndsAt: null, receipt: null, settle: {}, payout: null,
  };
  render(<UnclaimedList run={run} personId="s" onPutBack={vi.fn()} onBack={vi.fn()} />);
  expect(screen.getByText('Cosmic Crisp Apple ×2')).toBeTruthy();
  expect(screen.getByText('$2.20')).toBeTruthy();
});

test('stays-with names the count and the line total', () => {
  const run = {
    id: 'r', state: 'settled' as const, store: 'QFC', shopperId: 's', people, chips: [mk({ state: 'matched', receiptTotalCents: 219 })],
    taxRate: 0, lastCallEndsAt: null, receipt: null, settle: {}, payout: null,
  };
  expect(staysWith(run, 'Jake')).toBe('Cosmic Crisp Apple ×2, $2.19, stays with Jake.');
});

test('a counted chip with one line so far can still be paired with another line', () => {
  const receipt: ReceiptState = {
    lines: [
      { text: 'APPLE', cents: 110, quantity: 1, isTax: false },
      { text: 'APL', cents: 110, quantity: 1, isTax: false },
      { text: 'EGGS', cents: 872, quantity: 1, isTax: false },
    ],
    matches: [{ chipId: 'apple', lineIndex: 0, confidence: 1 }, { chipId: 'eggs', lineIndex: 2, confidence: 1 }],
    unmatchedLines: [1],
    cartQuantities: { apple: 2, eggs: 1, milk: 1 },
  };
  const chips = [
    mk({ quantity: 1, state: 'matched' }),
    mk({ id: 'eggs', name: 'Eggs', quantity: 1, state: 'matched' }),
    mk({ id: 'milk', name: 'Milk', quantity: 1, state: 'unmatched' }),
  ];
  // Apple was counted twice and has one line; eggs is full; milk has none.
  expect(pairableChips(receipt, chips).map((c) => c.id)).toEqual(['apple', 'milk']);
  render(<ReceiptMatch receipt={receipt} chips={chips} canFix onFix={vi.fn()} people={people} />);
  expect(screen.getByText('Cosmic Crisp Apple · yours')).toBeTruthy();
  // "Not on receipt" still lists only chips with no line at all.
  expect(screen.getByText('Not on receipt: Milk')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Pair with an item' }));
  expect(screen.getByRole('option', { name: 'Cosmic Crisp Apple' })).toBeTruthy();
  expect(screen.queryByRole('option', { name: 'Eggs' })).toBeNull();
});

test('a matched line names the chip with its count', () => {
  const receipt: ReceiptState = {
    lines: [{ text: '2 @ APPLE', cents: 219, quantity: 2, isTax: false }],
    matches: [{ chipId: 'apple', lineIndex: 0, confidence: 1 }],
    unmatchedLines: [],
  };
  render(<ReceiptMatch receipt={receipt} chips={[mk({ state: 'matched', claimers: ['a'] })]} canFix={false} onFix={vi.fn()} people={people} />);
  expect(screen.getByText('Cosmic Crisp Apple ×2 · Priya')).toBeTruthy();
});
