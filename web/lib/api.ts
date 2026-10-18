import { ApiError } from './api-error';
import { keyFor, saveKey } from './keys';
import type { Chip, ReceiptState, Run } from './types';

export const TEST_CARD = { number: '4111111111111111', expMonth: 12, expYear: 2031 };
const DECLINED_CARD = { ...TEST_CARD, expYear: 1998 };
/** The simulator holds this card fine but fails its capture at settle (shows "partly settled"). */
export const FAIL_CAPTURE_CARD = { ...TEST_CARD, number: '4000000000000341' };

export type JoinResult = {
  personId: string;
  /** This person's secret for the run; kept by `api.join` (lib/keys) and sent with every action. */
  key: string;
  auth: { status: string; authId: string | null; approvalCode: string; authorizedCents: number };
};

const TIMEOUT_MS = 10000;

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(path, {
      ...init,
      signal: AbortSignal.timeout(TIMEOUT_MS),
      headers: { 'content-type': 'application/json', ...((init?.headers as Record<string, string> | undefined) ?? {}) },
    });
  } catch (e) {
    const name = e instanceof Error || e instanceof DOMException ? e.name : '';
    if (name === 'TimeoutError' || name === 'AbortError') throw new ApiError('The server is taking too long. Try again.', 0);
    throw new ApiError("Can't reach the server. Check your connection and try again.", 0);
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new ApiError((body as { error?: string }).error ?? `request failed (${res.status})`, res.status);
  return body as T;
}

export type WishPicks = {
  list: { name: string; store?: string | null; items: { name: string; detail?: string | null }[] } | null;
  suggestions: { name: string; reason: string }[];
};

const run = (runId: string) => `/api/runs/${encodeURIComponent(runId)}`;

/** A POST acting as `personId` in the run: carries that person's key, when this browser has it. */
function act<T>(runId: string, personId: string, path: string, body: unknown): Promise<T> {
  const key = keyFor(runId, personId);
  return call<T>(path, { method: 'POST', body: JSON.stringify(body), headers: key ? { 'x-dibs-key': key } : {} });
}

export const api = {
  // Fastify rejects a JSON content-type with an empty body, so send an empty object.
  createRun: async () => {
    const r = await call<{ runId: string; shopperId: string; key: string }>('/api/runs', { method: 'POST', body: '{}' });
    if (r.key) saveKey(r.runId, r.shopperId, r.key);
    return r;
  },
  getRun: (runId: string) => call<Run>(`/api/runs/${encodeURIComponent(runId)}`),
  join: async (runId: string, name: string, capCents: number, opts: { decline?: boolean; failCapture?: boolean } = {}) => {
    const r = await call<JoinResult>(`/api/runs/${encodeURIComponent(runId)}/join`, {
      method: 'POST',
      body: JSON.stringify({
        name,
        card: opts.decline ? DECLINED_CARD : opts.failCapture ? FAIL_CAPTURE_CARD : TEST_CARD,
        capCents,
      }),
    });
    if (r.key) saveKey(runId, r.personId, r.key);
    return r;
  },
  // Shopper-only calls without a personId in the body still name the shopper, to pick the key.
  addChip: (runId: string, shopperId: string, body: { imageBase64: string; hint?: string }) =>
    act<Chip>(runId, shopperId, `${run(runId)}/chips`, body),
  fixChip: (runId: string, chipId: string, personId: string, fix: { name?: string; priceCents?: number }) =>
    act<Run>(runId, personId, `${run(runId)}/chips/${encodeURIComponent(chipId)}/fix`, { personId, ...fix }),
  setQuantity: (runId: string, chipId: string, personId: string, quantity: number) =>
    act<Run>(runId, personId, `${run(runId)}/chips/${encodeURIComponent(chipId)}/quantity`, { personId, quantity }),
  putBack: (runId: string, chipId: string, personId: string) =>
    act<Run>(runId, personId, `${run(runId)}/chips/${encodeURIComponent(chipId)}/putback`, { personId }),
  checkout: (runId: string, personId: string) => act<Run>(runId, personId, `${run(runId)}/checkout`, { personId }),
  back: (runId: string, personId: string) => act<Run>(runId, personId, `${run(runId)}/back`, { personId }),
  raise: (runId: string, personId: string, capCents: number) =>
    act<{ authorizedCents: number }>(runId, personId, `${run(runId)}/raise`, { personId, capCents }),
  /** What the Wish sheet offers: the household list (when the server reads one) and suggestions from past runs. */
  wishPicks: (runId: string, personId: string) => {
    const key = keyFor(runId, personId);
    return call<WishPicks>(`${run(runId)}/wish-picks?personId=${encodeURIComponent(personId)}`, { headers: key ? { 'x-dibs-key': key } : {} });
  },
  wish: (runId: string, name: string, byPersonId: string) =>
    act<Run>(runId, byPersonId, `${run(runId)}/chips/text`, { name, byPersonId }),
  receipt: (runId: string, shopperId: string, imageBase64: string) =>
    act<ReceiptState>(runId, shopperId, `${run(runId)}/receipt`, { imageBase64 }),
  fixReceiptLine: (runId: string, shopperId: string, lineIndex: number, target: { chipId: string } | 'mine') =>
    act<ReceiptState>(runId, shopperId, `${run(runId)}/receipt/fix`, { lineIndex, target }),
  confirm: (runId: string, personId: string) => act<Run>(runId, personId, `${run(runId)}/confirm`, { personId }),
};
