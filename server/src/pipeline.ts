// Identify an item: crop, vision, then sticker price now or a web price later.
import sharp from 'sharp';
import type { PriceProvider } from './price/provider.js';
import type { ServerMsg } from './protocol.js';
import { recentSameName, addChip, setChipLive, setChipPrice } from './run.js';
import type { Store } from './store.js';
import type { Box } from './types.js';
import type { VisionProvider } from './vision/provider.js';

export type PipelineDeps = {
  store: Store;
  vision: VisionProvider;
  price: PriceProvider;
  now: () => number;
  /** Delivers a message to the run's shopper socket only. */
  /** Chip ids whose identify is running; a retry for one of them is a no-op. */
  inflight?: Set<string>;
  toShopper?: (runId: string, msg: ServerMsg) => void;
};

export type IdentifyResult = { chipId: string | null; error?: 'cart closed' | 'identify failed' };

/** Crops `region` out of a JPEG frame (clamped to the frame) and returns a JPEG data URL, or null if it cannot. */
export async function cropDataUrl(frameBase64: string, region: Box): Promise<string | null> {
  try {
    const img = sharp(Buffer.from(frameBase64, 'base64'));
    const m = await img.metadata();
    const fw = m.width ?? 1;
    const fh = m.height ?? 1;
    const left = Math.max(0, Math.min(Math.round(region.x), fw - 1));
    const top = Math.max(0, Math.min(Math.round(region.y), fh - 1));
    const out = await img
      .extract({
        left,
        top,
        width: Math.max(1, Math.min(Math.round(region.w), fw - left)),
        height: Math.max(1, Math.min(Math.round(region.h), fh - top)),
      })
      .jpeg({ quality: 85 })
      .toBuffer();
    return `data:image/jpeg;base64,${out.toString('base64')}`;
  } catch {
    return null;
  }
}

/**
 * Creates (or reuses `retryChipId`) an identifying chip, identifies it and makes it live.
 * A failed identify removes the chip only when `removeOnFail` is set; otherwise it stays identifying for a retry.
 */
export async function identifyChip(
  deps: PipelineDeps,
  runId: string,
  frameBase64: string,
  region: Box | null,
  opts: { retryChipId?: string; hint?: string; removeOnFail?: boolean } = {},
): Promise<IdentifyResult> {
  if (opts.retryChipId && deps.inflight?.has(opts.retryChipId)) return { chipId: opts.retryChipId };
  const { store, vision, price, now } = deps;
  const run = store.get(runId);
  if (!run) return { chipId: null, error: 'cart closed' };
  let id = opts.retryChipId ?? '';
  if (opts.retryChipId) {
    const c = run.chips.find((x) => x.id === opts.retryChipId);
    if (!c || c.state !== 'identifying' || c.dropped) return { chipId: null, error: 'cart closed' };
    region = region ?? c.region;
  } else {
    id = crypto.randomUUID();
    const photoUrl = region && frameBase64 ? await cropDataUrl(frameBase64, region) : null;
    const added = store.update(runId, (r) =>
      addChip(r, { id, name: '', priceCents: null, priceSource: 'none', photoUrl, region, quantity: 1 }, now()),
    );
    if ('error' in added || !added.run.chips.some((c) => c.id === id)) return { chipId: null, error: 'cart closed' };
  }
  deps.inflight?.add(id);
  try {
    return await identifyLive(deps, runId, id, frameBase64, region, run.store, opts);
  } finally {
    deps.inflight?.delete(id);
  }
}

async function identifyLive(
  deps: PipelineDeps,
  runId: string,
  id: string,
  frameBase64: string,
  region: Box | null,
  storeName: string,
  opts: { hint?: string; removeOnFail?: boolean },
): Promise<IdentifyResult> {
  const { store, vision, price, now } = deps;
  if (region) deps.store.broadcast(runId, { t: 'identifying', region });

  let found;
  try {
    const cartNames = (store.get(runId)?.chips ?? [])
      .filter((c) => c.id !== id && c.state !== 'removed' && c.state !== 'identifying' && c.name)
      .map((c) => c.name);
    found = await vision.identify(frameBase64, opts.hint, region ?? undefined, { runId, cartNames });
  } catch {
    if (opts.removeOnFail) store.update(runId, (r) => ({ ...r, chips: r.chips.filter((c) => c.id !== id) }));
    return { chipId: id, error: 'identify failed' };
  }
  if (process.env.MERGE_DUPLICATES === '1') {
    const cur = store.get(runId);
    const same = cur ? recentSameName(cur, found.name, now(), id) : undefined;
    if (same) {
      // The camera saw the same product again (a merged box, a re-detection, a double tap): keep one chip.
      store.update(runId, (r) => ({ ...r, chips: r.chips.filter((c) => c.id !== id) }));
      return { chipId: same.id };
    }
  }
  const source = found.priceCents === null ? 'none' : 'sticker';
  const crop = found.cropBase64 ? `data:image/jpeg;base64,${found.cropBase64}` : null;
  const live = store.update(runId, (r) => {
    const next = setChipLive(r, id, found.name, found.priceCents, source, now());
    if (!crop || !next.chips.some((x) => x.id === id)) return next;
    return { ...next, chips: next.chips.map((x) => (x.id === id ? { ...x, photoUrl: crop } : x)) };
  });
  if ('error' in live || !live.run.chips.some((c) => c.id === id)) return { chipId: null, error: 'cart closed' };

  if (found.priceCents === null) {
    void price
      .lookup(found.name, storeName)
      .then((hit) => {
        if (!hit) return;
        // Discard a late price unless the chip is still unpriced and the run still takes changes.
        store.update(runId, (r) => {
          const c = r.chips.find((x) => x.id === id);
          const open = r.state === 'open' || r.state === 'lastCall';
          if (!c || !open || c.priceSource !== 'none' || c.state === 'removed' || c.dropped) return r;
          return setChipPrice(r, id, hit.cents, 'web');
        });
      })
      .catch(() => undefined);
  }
  return { chipId: id };
}

export async function identifyPipeline(
  deps: PipelineDeps,
  runId: string,
  frameBase64: string,
  region: Box,
  retryChipId?: string,
): Promise<void> {
  const res = await identifyChip(deps, runId, frameBase64, region, { retryChipId });
  if (res.error === 'identify failed') deps.toShopper?.(runId, { t: 'error', reason: 'identify failed' });
}
