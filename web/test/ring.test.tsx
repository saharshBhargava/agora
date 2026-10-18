import { render } from '@testing-library/react';
import { expect, test } from 'vitest';
import { Ring } from '@/components/Ring';
import type { Person } from '@/lib/types';

const p = (id: string, initial: string): Person => ({
  id, name: initial, initial, isShopper: false, authorizedCents: 4000, authId: null, approvalCode: null, payoutPan: null,
});
const people = ['A', 'B', 'C', 'D', 'E'].map((x) => p(x.toLowerCase(), x));

test('n=0 renders nothing', () => {
  const { container } = render(<Ring claimers={[]} me="a" people={people} />);
  expect(container.firstChild).toBeNull();
});

test('n=1 is a full ring with an open notch', () => {
  const { container } = render(<Ring claimers={[people[0]]} me="a" people={people} />);
  expect(container.querySelector('[data-notch]')).not.toBeNull();
});

test('n=2 renders two segments with initials A and B, own segment thicker', () => {
  const { container, getByText } = render(<Ring claimers={people.slice(0, 2)} me="a" people={people} />);
  const segs = container.querySelectorAll('[data-segment]');
  expect(segs).toHaveLength(2);
  getByText('A');
  getByText('B');
  expect(Number(segs[0].getAttribute('stroke-width'))).toBeGreaterThan(Number(segs[1].getAttribute('stroke-width')));
});

test('n=5 shows the count in the center', () => {
  const { getByText, container } = render(<Ring claimers={people} me="a" people={people} />);
  getByText('5');
  expect(container.querySelectorAll('[data-segment]')).toHaveLength(0);
});
