import { describe, expect, it } from 'vitest';
import { createFrameRelay, shouldSendFrame } from '../src/relay.js';

describe('relay', () => {
  it('skips a backed-up socket', () => {
    expect(shouldSendFrame(0)).toBe(true);
    expect(shouldSendFrame(250_000)).toBe(false);
    expect(shouldSendFrame(250_000, 300_000)).toBe(true);
  });
  it('keeps only the latest frame per run and drops it on demand', () => {
    const r = createFrameRelay();
    r.set('a', { jpegBase64: '1', at: 1 });
    r.set('a', { jpegBase64: '2', at: 2 });
    expect(r.get('a')?.jpegBase64).toBe('2');
    r.drop('a');
    expect(r.get('a')).toBeUndefined();
  });
});
