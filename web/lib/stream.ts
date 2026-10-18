/**
 * Hands the shopper's live camera stream from the cart screen to the receipt camera, so moving to settle
 * (a client-side navigation) reuses the same stream instead of asking for the camera again.
 */
const LINGER_MS = 60000;
let parked: MediaStream | null = null;
let timer: ReturnType<typeof setTimeout> | undefined;

const live = (s: MediaStream | null): s is MediaStream =>
  !!s && s.getTracks().length > 0 && s.getTracks().every((t) => t.readyState === 'live');

/** A parked live stream, if any; the caller now owns it. */
export function takeParkedStream(): MediaStream | null {
  if (timer) clearTimeout(timer);
  timer = undefined;
  const s = parked;
  parked = null;
  if (live(s)) return s;
  (s as MediaStream | null)?.getTracks().forEach((t) => t.stop());
  return null;
}

/** Keep a stream alive for a short while for the next camera; stopped if nobody takes it. */
export function parkStream(s: MediaStream): void {
  if (parked && parked !== s) parked.getTracks().forEach((t) => t.stop());
  if (timer) clearTimeout(timer);
  parked = s;
  timer = setTimeout(() => {
    s.getTracks().forEach((t) => t.stop());
    if (parked === s) parked = null;
  }, LINGER_MS);
}
