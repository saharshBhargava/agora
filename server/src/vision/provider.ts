import type { Box } from '../types.js';
import { GeminiVision } from './gemini.js';
import { StubVision } from './stub.js';

export type Identified = { name: string; priceCents: number | null; cropBase64: string; confidence: number; barcode: string | null };
export type RawReceiptLine = { text: string; cents: number; quantity: number };
export type MatchLine = RawReceiptLine & { isTax: boolean };
export type MatchChip = { id: string; name: string; priceCents: number | null };

/** `cartNames`: names already in the run, so the same product keeps one name across detections. */
export type IdentifyContext = { runId: string; cartNames?: string[] };

export interface VisionProvider {
  /** `context` lets a provider keep per-run state (the stub's drop order). */
  identify(imageBase64: string, hint?: string, region?: Box, context?: IdentifyContext): Promise<Identified>;
  readReceipt(imageBase64: string): Promise<RawReceiptLine[]>;
  /**
   * Optional: proposes receipt line to chip pairs (`{ lineIndex, chipId, confidence }`). The reply is
   * untrusted; `matchReceipt` in settle.ts validates it. Providers without it use token overlap only.
   */
  matchReceipt?(lines: MatchLine[], chips: MatchChip[]): Promise<unknown[]>;
}

export function getVision(): VisionProvider {
  const mode = process.env.VISION ?? 'stub';
  if (mode === 'stub') return new StubVision();
  if (mode === 'gemini') {
    if (!process.env.GEMINI_API_KEY) throw new Error('VISION=gemini requires GEMINI_API_KEY');
    return new GeminiVision();
  }
  throw new Error(`VISION=${mode} is not wired yet`);
}
