import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import type { Box } from '../types.js';
import { PROPS } from '../price/stub.js';
import type { IdentifyContext, Identified, RawReceiptLine, VisionProvider } from './provider.js';

const assets = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'assets');
const SIZE = 32;
const MARGIN = 8; // minimum gap between best and second-best mean difference to be conclusive

const thumb = (input: Buffer): Promise<Buffer> => sharp(input).resize(SIZE, SIZE, { fit: 'fill' }).removeAlpha().raw().toBuffer();
const mad = (a: Buffer, b: Buffer): number => {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += Math.abs(a[i] - b[i]);
  return s / a.length;
};

export class StubVision implements VisionProvider {
  /** Index into PROPS (the drop order eggs, towels, milk) of the last prop returned per run. */
  private readonly lastByRun = new Map<string, number>();
  private props: Promise<{ prop: (typeof PROPS)[number]; jpeg: Buffer; thumb: Buffer }[]> | null = null;

  private load() {
    this.props ??= Promise.all(
      PROPS.map(async (prop) => {
        const jpeg = readFileSync(join(assets, 'props', `${prop.key}.jpg`));
        return { prop, jpeg, thumb: await thumb(jpeg) };
      }),
    );
    return this.props;
  }

  async identify(imageBase64: string, hint?: string, region?: Box, context?: IdentifyContext): Promise<Identified> {
    const props = await this.load();
    const h = hint?.toLowerCase().trim();
    const hinted = h ? props.find((p) => h.includes(p.prop.key) || p.prop.words.some((w) => h.includes(w))) : undefined;
    let crop: Buffer | null = null;
    if (imageBase64) {
      let img = sharp(Buffer.from(imageBase64, 'base64'));
      if (region) {
        const m = await img.metadata();
        const left = Math.max(0, Math.min(region.x, (m.width ?? 1) - 1));
        const top = Math.max(0, Math.min(region.y, (m.height ?? 1) - 1));
        img = img.extract({
          left,
          top,
          width: Math.max(1, Math.min(region.w, (m.width ?? 1) - left)),
          height: Math.max(1, Math.min(region.h, (m.height ?? 1) - top)),
        });
      }
      crop = await img.jpeg({ quality: 85 }).toBuffer();
    }
    // Inconclusive without a hint: the next prop in drop order for this run, cycling.
    const runKey = context?.runId ?? '';
    const last = this.lastByRun.get(runKey);
    let chosen = hinted ?? props[last === undefined ? 0 : (last + 1) % props.length];
    let confidence = hinted ? 1 : 0.5;
    if (!hinted && crop) {
      const t = await thumb(crop);
      const scored = props.map((p) => ({ p, d: mad(t, p.thumb) })).sort((a, b) => a.d - b.d);
      if (scored[1].d - scored[0].d >= MARGIN) {
        chosen = scored[0].p;
        confidence = Math.min(0.99, 1 - scored[0].d / 255);
      }
    }
    this.lastByRun.set(runKey, props.indexOf(chosen));
    return {
      name: chosen.prop.name,
      priceCents: chosen.prop.cents,
      cropBase64: (crop ?? chosen.jpeg).toString('base64'),
      confidence,
      barcode: null,
    };
  }

  async readReceipt(_imageBase64: string): Promise<RawReceiptLine[]> {
    return JSON.parse(readFileSync(join(assets, 'receipt.json'), 'utf8')) as RawReceiptLine[];
  }
}
