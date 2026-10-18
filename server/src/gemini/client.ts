export type GeminiPart = { text?: string; thought?: boolean; [k: string]: unknown };
export type GeminiResponse = {
  candidates?: {
    content?: { parts?: GeminiPart[] };
    finishReason?: string;
    groundingMetadata?: { groundingChunks?: { web?: { uri?: string; title?: string } }[] };
  }[];
  promptFeedback?: { blockReason?: string };
};

export class GeminiError extends Error {
  constructor(
    public readonly kind: 'blocked' | 'incomplete' | 'http' | 'timeout',
    message: string,
  ) {
    super(message);
    this.name = 'GeminiError';
  }
}

/** Models to try in order. New API keys can't use retired models (404) and busy ones return 503 or 429. */
export const geminiModels = (): string[] =>
  (process.env.GEMINI_MODEL || 'gemini-3.6-flash,gemini-3.5-flash,gemini-3.5-flash-lite')
    .split(',')
    .map((m) => m.trim())
    .filter(Boolean);

/** Statuses that mean "this model can't answer now; the next one might". */
const FALL_THROUGH = new Set([404, 429, 500, 503]);

export async function generate(
  body: object,
  opts: { timeoutMs?: number; fetchImpl?: typeof fetch; apiKey?: string } = {},
): Promise<GeminiResponse> {
  const key = opts.apiKey ?? process.env.GEMINI_API_KEY;
  if (!key) throw new GeminiError('http', 'GEMINI_API_KEY is not set');
  const f = opts.fetchImpl ?? fetch;
  // One deadline covers every model tried, so callers' timeouts still hold.
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), opts.timeoutMs ?? 30_000);
  let last: GeminiError = new GeminiError('http', 'no Gemini model configured');
  try {
    for (const model of geminiModels()) {
      const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;
      const res = await f(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-goog-api-key': key },
        body: JSON.stringify(body),
        signal: ctl.signal,
      });
      if (res.ok) return (await res.json()) as GeminiResponse;
      last = new GeminiError('http', `Gemini HTTP ${res.status} (${model})`);
      if (!FALL_THROUGH.has(res.status)) break;
    }
    throw last;
  } catch (e) {
    if (e instanceof GeminiError) throw e;
    if (ctl.signal.aborted) throw new GeminiError('timeout', 'Gemini request timed out');
    throw e;
  } finally {
    clearTimeout(timer);
  }
}
