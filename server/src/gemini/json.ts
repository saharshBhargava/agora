import { GeminiError, type GeminiResponse } from './client.js';

export function responseText(r: GeminiResponse): string {
  if (r.promptFeedback?.blockReason) throw new GeminiError('blocked', `blocked: ${r.promptFeedback.blockReason}`);
  const c = r.candidates?.[0];
  if (!c) throw new GeminiError('incomplete', 'no candidates');
  if (c.finishReason && c.finishReason !== 'STOP') throw new GeminiError('incomplete', `finishReason ${c.finishReason}`);
  const text = (c.content?.parts ?? [])
    .filter((p) => !p.thought && typeof p.text === 'string')
    .map((p) => p.text as string)
    .join('');
  if (!text.trim()) throw new GeminiError('incomplete', 'empty response');
  return text;
}

/** Tries each balanced `{...}` group left to right until one parses as JSON. */
export function firstJSONObject(text: string): string | null {
  for (let start = text.indexOf('{'); start !== -1; start = text.indexOf('{', start + 1)) {
    let depth = 0;
    let inStr = false;
    let esc = false;
    for (let i = start; i < text.length; i++) {
      const ch = text[i];
      if (inStr) {
        if (esc) esc = false;
        else if (ch === '\\') esc = true;
        else if (ch === '"') inStr = false;
        continue;
      }
      if (ch === '"') inStr = true;
      else if (ch === '{') depth++;
      else if (ch === '}' && --depth === 0) {
        const cand = text.slice(start, i + 1);
        try {
          JSON.parse(cand);
          return cand;
        } catch {
          /* try the next start */
        }
        break;
      }
    }
  }
  return null;
}

export function groundingSources(r: GeminiResponse): { uri: string; title: string }[] {
  const out: { uri: string; title: string }[] = [];
  for (const g of r.candidates?.[0]?.groundingMetadata?.groundingChunks ?? []) {
    if (g.web?.uri) out.push({ uri: g.web.uri, title: g.web.title ?? '' });
  }
  return out;
}
