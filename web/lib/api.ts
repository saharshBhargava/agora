import type { Run } from './types';

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
  if (!res.ok) throw new Error((body as { error?: string }).error ?? `request failed (${res.status})`);
  return body as T;
}

export const api = {
  createRun: () => call<{ runId: string; shopperId: string }>('/api/runs', { method: 'POST' }),
  getRun: (runId: string) => call<Run>(`/api/runs/${encodeURIComponent(runId)}`),
  join: (runId: string, name: string, capCents: number, opts: { decline?: boolean } = {}) =>
    call<JoinResult>(`/api/runs/${encodeURIComponent(runId)}/join`, {
      method: 'POST',
      body: JSON.stringify({ name, card: opts.decline ? DECLINED_CARD : TEST_CARD, capCents }),
    }),
};
