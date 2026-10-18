import { ApiError } from './api-error';
import type { Chip, ReceiptState, Run } from './types';

export const TEST_CARD = { number: '4111111111111111', expMonth: 12, expYear: 2031 };
const DECLINED_CARD = { ...TEST_CARD, expYear: 1998 };

export type JoinResult = {
  personId: string;
  auth: { status: string; authId: string; approvalCode: string; authorizedCents: number };
};

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, {
    ...init,
    headers: { 'content-type': 'application/json', ...(init?.headers ?? {}) },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new ApiError((body as { error?: string }).error ?? `request failed (${res.status})`, res.status);
  return body as T;
}

const run = (runId: string) => `/api/runs/${encodeURIComponent(runId)}`;

export const api = {
  createRun: () => call<{ runId: string; shopperId: string }>('/api/runs', { method: 'POST' }),
  getRun: (runId: string) => call<Run>(`/api/runs/${encodeURIComponent(runId)}`),
  join: (runId: string, name: string, capCents: number, opts: { decline?: boolean } = {}) =>
    call<JoinResult>(`/api/runs/${encodeURIComponent(runId)}/join`, {
      method: 'POST',
      body: JSON.stringify({ name, card: opts.decline ? DECLINED_CARD : TEST_CARD, capCents }),
    }),
  addChip: (runId: string, body: { imageBase64: string; hint?: string }) =>
    call<Chip>(`${run(runId)}/chips`, { method: 'POST', body: JSON.stringify(body) }),
  fixChip: (runId: string, chipId: string, personId: string, fix: { name?: string; priceCents?: number }) =>
    call<Run>(`${run(runId)}/chips/${encodeURIComponent(chipId)}/fix`, {
      method: 'POST',
      body: JSON.stringify({ personId, ...fix }),
    }),
  putBack: (runId: string, chipId: string, personId: string) =>
    call<Run>(`${run(runId)}/chips/${encodeURIComponent(chipId)}/putback`, {
      method: 'POST',
      body: JSON.stringify({ personId }),
    }),
  checkout: (runId: string, personId: string) =>
    call<Run>(`${run(runId)}/checkout`, { method: 'POST', body: JSON.stringify({ personId }) }),
  back: (runId: string, personId: string) =>
    call<Run>(`${run(runId)}/back`, { method: 'POST', body: JSON.stringify({ personId }) }),
  raise: (runId: string, personId: string, capCents: number) =>
    call<{ authorizedCents: number }>(`${run(runId)}/raise`, { method: 'POST', body: JSON.stringify({ personId, capCents }) }),
  wish: (runId: string, name: string, byPersonId: string) =>
    call<Run>(`${run(runId)}/chips/text`, { method: 'POST', body: JSON.stringify({ name, byPersonId }) }),
  receipt: (runId: string, imageBase64: string) =>
    call<ReceiptState>(`${run(runId)}/receipt`, { method: 'POST', body: JSON.stringify({ imageBase64 }) }),
  fixReceiptLine: (runId: string, lineIndex: number, target: { chipId: string } | 'mine') =>
    call<ReceiptState>(`${run(runId)}/receipt/fix`, { method: 'POST', body: JSON.stringify({ lineIndex, target }) }),
  confirm: (runId: string, personId: string) =>
    call<Run>(`${run(runId)}/confirm`, { method: 'POST', body: JSON.stringify({ personId }) }),
};
