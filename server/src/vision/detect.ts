import type { Box } from '../types.js';
import { DiffDetector } from './detect-diff.js';

export type DetectEvent = { kind: 'newItem'; at: number; region: Box; frameBase64: string } | { kind: 'changing' };

/** push is async because frames are decoded with sharp; calls are processed in order. */
export interface Detector {
  push(frame: { jpegBase64: string; at: number }): Promise<DetectEvent[]>;
}

export function getDetector(): Detector {
  const mode = process.env.DETECTOR ?? 'diff';
  if (mode === 'diff') return new DiffDetector({ settleMs: 1000, minChangedFraction: 0.04 });
  throw new Error(`DETECTOR=${mode} is not wired yet`);
}
