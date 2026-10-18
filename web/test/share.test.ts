import { expect, test } from 'vitest';
import { roomFor, splitChip } from '@/lib/share';

test('splitChip parity with server vectors', () => {
  expect([...splitChip(872, ['a', 'b'])]).toEqual([['a', 436], ['b', 436]]);
  expect([...splitChip(800, ['a', 'b', 'c'])]).toEqual([['a', 267], ['b', 267], ['c', 266]]);
  expect([...splitChip(1001, ['a', 'b', 'c'])]).toEqual([['a', 334], ['b', 334], ['c', 333]]);
});
test('roomFor with tax', () => {
  expect(roomFor([100], 1000, 0.1)).toBe(890);
});
