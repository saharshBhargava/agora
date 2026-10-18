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

export const geminiModel = (): string => process.env.GEMINI_MODEL || 'gemini-flash-latest';

export async function generate(
  body: object,
  opts: { timeoutMs?: number; fetchImpl?: typeof fetch; apiKey?: string } = {},
): Promise<GeminiResponse> {
  const key = opts.apiKey ?? process.env.GEMINI_API_KEY;
  if (!key) throw new GeminiError('http', 'GEMINI_API_KEY is not set');
  const f = opts.fetchImpl ?? fetch;
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${geminiModel()}:generateContent`;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), opts.timeoutMs ?? 30_000);
  try {
    const res = await f(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify(body),
      signal: ctl.signal,
    });
    if (!res.ok) throw new GeminiError('http', `Gemini HTTP ${res.status}`);
    return (await res.json()) as GeminiResponse;
  } catch (e) {
    if (e instanceof GeminiError) throw e;
    if (ctl.signal.aborted) throw new GeminiError('timeout', 'Gemini request timed out');
    throw e;
  } finally {
    clearTimeout(timer);
  }
}
