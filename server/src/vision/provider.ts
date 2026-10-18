import type { Box } from '../types.js';
import { StubVision } from './stub.js';

export type Identified = { name: string; priceCents: number | null; cropBase64: string; confidence: number; barcode: string | null };
export type RawReceiptLine = { text: string; cents: number; quantity: number };

export interface VisionProvider {
  identify(imageBase64: string, hint?: string, region?: Box): Promise<Identified>;
  readReceipt(imageBase64: string): Promise<RawReceiptLine[]>;
}

export function getVision(): VisionProvider {
  const mode = process.env.VISION ?? 'stub';
  if (mode === 'stub') return new StubVision();
  throw new Error(`VISION=${mode} is not wired yet`);
}
