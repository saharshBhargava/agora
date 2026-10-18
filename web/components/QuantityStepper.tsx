'use client';
import { useEffect, useState } from 'react';
import { MAX_QUANTITY, stepQuantity } from '@/lib/share';

/**
 * A compact "− N +" for how many of an item are in the cart (1 to 20). − is disabled at 1: removing an
 * item is still the remove zone or Remove. When `onChange` returns a promise (a server call), the new
 * count shows at once, the buttons wait for that call, and the server's count takes over again once it
 * arrives (or at once if the call fails). A plain `onChange` is a local control: `quantity` is the value.
 */
export function QuantityStepper({
  name,
  quantity,
  onChange,
  disabled = false,
}: {
  name: string;
  quantity: number;
  onChange: (quantity: number) => Promise<unknown> | void;
  disabled?: boolean;
}) {
  const [shown, setShown] = useState<number | null>(null);
  const [sending, setSending] = useState(false);
  // A new count from the server replaces the guess.
  useEffect(() => {
    if (!sending) setShown(null);
  }, [quantity]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (sending || shown === null) return;
    if (quantity === shown) {
      setShown(null);
      return;
    }
    const t = setTimeout(() => setShown(null), 3000);
    return () => clearTimeout(t);
  }, [sending, shown, quantity]);

  const value = shown ?? quantity;
  const step = (delta: 1 | -1) => {
    const next = stepQuantity(value, delta);
    if (next === null || sending) return;
    const r = onChange(next);
    if (!(r instanceof Promise)) return;
    setShown(next);
    setSending(true);
    r.then(
      () => setSending(false),
      () => {
        setSending(false);
        setShown(null);
      },
    );
  };

  return (
    <span className="qty-stepper" role="group" aria-label={`How many ${name}`}>
      <button
        type="button"
        className="qty-btn"
        aria-label={`One fewer ${name}`}
        disabled={disabled || sending || value <= 1}
        onClick={() => step(-1)}
      >
        −
      </button>
      <span className="qty-num" aria-live="polite">{value}</span>
      <button
        type="button"
        className="qty-btn"
        aria-label={`One more ${name}`}
        disabled={disabled || sending || value >= MAX_QUANTITY}
        onClick={() => step(1)}
      >
        +
      </button>
    </span>
  );
}
