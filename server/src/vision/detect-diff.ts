// Frame-differencing cart detector. Timing comes from the frame's `at`, never the wall clock.
import sharp from 'sharp';
import type { Box } from '../types.js';
import type { DetectEvent, Detector } from './detect.js';

const TW = 64;
const TH = 48;
const PIXEL_DELTA = 30;
const STILL_PX = 2;
/** A settled change whose bounding box covers more of the frame than this is a lighting / exposure shift. */
const MAX_ITEM_FRACTION = 0.6;

type Bounds = { x0: number; y0: number; x1: number; y1: number };

export class DiffDetector implements Detector {
  private baseline: Buffer | null = null;
  private pending: { bounds: Bounds; stillSince: number } | null = null;
  private queue: Promise<unknown> = Promise.resolve();

  constructor(private readonly opts: { settleMs: number; minChangedFraction: number }) {}

  push(frame: { jpegBase64: string; at: number }): Promise<DetectEvent[]> {
    const run = this.queue.then(() => this.process(frame));
    this.queue = run.catch(() => undefined);
    return run;
  }

  private async process(frame: { jpegBase64: string; at: number }): Promise<DetectEvent[]> {
    const jpeg = Buffer.from(frame.jpegBase64, 'base64');
    const meta = await sharp(jpeg).metadata();
    const thumb = await sharp(jpeg).resize(TW, TH, { fit: 'fill' }).grayscale().raw().toBuffer();
    if (!this.baseline) {
      this.baseline = thumb;
      return [];
    }
    let n = 0;
    const b: Bounds = { x0: TW, y0: TH, x1: -1, y1: -1 };
    for (let i = 0; i < thumb.length; i++) {
      if (Math.abs(thumb[i] - this.baseline[i]) <= PIXEL_DELTA) continue;
      const x = i % TW;
      const y = (i - x) / TW;
      n++;
      if (x < b.x0) b.x0 = x;
      if (x > b.x1) b.x1 = x;
      if (y < b.y0) b.y0 = y;
      if (y > b.y1) b.y1 = y;
    }
    if (n / thumb.length < this.opts.minChangedFraction) {
      this.pending = null;
      return [];
    }
    const prev = this.pending;
    const moved = !prev || Math.max(Math.abs(b.x0 - prev.bounds.x0), Math.abs(b.y0 - prev.bounds.y0), Math.abs(b.x1 - prev.bounds.x1), Math.abs(b.y1 - prev.bounds.y1)) >= STILL_PX;
    if (moved) {
      this.pending = { bounds: b, stillSince: frame.at };
      return [{ kind: 'changing' }];
    }
    this.pending = { bounds: b, stillSince: prev.stillSince };
    if (frame.at - prev.stillSince < this.opts.settleMs) return [];
    this.baseline = thumb;
    this.pending = null;
    if (((b.x1 + 1 - b.x0) * (b.y1 + 1 - b.y0)) / (TW * TH) > MAX_ITEM_FRACTION) return [];
    const sx = (meta.width ?? TW) / TW;
    const sy = (meta.height ?? TH) / TH;
    const region: Box = {
      x: Math.floor(b.x0 * sx),
      y: Math.floor(b.y0 * sy),
      w: Math.ceil((b.x1 + 1 - b.x0) * sx),
      h: Math.ceil((b.y1 + 1 - b.y0) * sy),
    };
    return [{ kind: 'newItem', at: frame.at, region, frameBase64: frame.jpegBase64 }];
  }
}
