// Reads a Kroger-family (QFC) search results page's visible text without a model call.
// The page renders each product as: price line(s), optional "about $X each", unit rate, name, size, badges.

export type PageProduct = { name: string; priceCents: number; eachCents: number | null };

const PRICE = /^\$(\d{1,4})\.(\d{2})$/;
const ABOUT_EACH = /^about \$(\d{1,4})\.(\d{2}) each$/i;
const NOISE = [
  /^about$/i, /^each$/i, /^snap ebt$/i, /^sign in to add$/i, /^sponsored$/i, /^add to cart$/i, /^view offer$/i,
  /^\$\d+\.\d{2}\/(lb|oz|fl oz|ct|each)$/i, /^sale:/i, /^\d+ for \$\d/i, /big deal!?$/i,
  /^\d+(\.\d+)?\s*(lb|lbs|oz|fl oz|ct|each|pk|gal|qt|pt|l|ml|g|kg)(\s*\/\s*\d+(\.\d+)?\s*(fl oz|oz|ct))?$/i,
];

const cents = (m: RegExpMatchArray): number => Number(m[1]) * 100 + Number(m[2]);

/** Products in page order. Only lines after the "N results" marker are read when it is present. */
export function parseQfcPage(text: string): PageProduct[] {
  const lines = text.split('\n').map((l) => l.trim()).filter(Boolean);
  const start = lines.findIndex((l) => /^\d[\d,]* results?$/i.test(l));
  const out: PageProduct[] = [];
  let price: number | null = null;
  let each: number | null = null;
  for (const line of lines.slice(start >= 0 ? start + 1 : 0)) {
    if (/^load more results$/i.test(line) || /^back to top$/i.test(line)) break;
    const p = line.match(PRICE);
    if (p) {
      if (price === null) price = cents(p);
      continue;
    }
    const a = line.match(ABOUT_EACH);
    if (a) {
      each = cents(a);
      continue;
    }
    if (NOISE.some((r) => r.test(line))) continue;
    if (price !== null && /[a-z]{3}/i.test(line) && line.length >= 6) {
      out.push({ name: line, priceCents: each ?? price, eachCents: each });
      price = null;
      each = null;
    }
  }
  return out;
}

const STOP = new Set(['the', 'a', 'an', 'of', 'and', 'with', 'fresh', 'large', 'small', 'each', 'oz', 'fl', 'ct', 'lb', 'pk']);
const tokens = (s: string): string[] =>
  s.toLowerCase().replace(/[®™©]/g, '').replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter((t) => t.length > 1 && !STOP.has(t));
const MULTI = /\b(\d+\s*(pk|pack|ct|count)|bag|tray|case|bundle)\b/i;

/**
 * The best product for an item name, or null when nothing on the page clearly matches.
 * Score is the share of the item's words found in the product name; single units beat packs on ties.
 */
export function matchProduct(item: string, products: PageProduct[], minScore = 0.6): PageProduct | null {
  const want = tokens(item).map((t) => t.replace(/s$/, ''));
  if (want.length === 0) return null;
  let best: { p: PageProduct; score: number } | null = null;
  for (const p of products) {
    const have = new Set(tokens(p.name).map((t) => t.replace(/s$/, '')));
    const hits = want.filter((t) => have.has(t)).length;
    let score = hits / want.length;
    // Prefer the tighter name: "Apple" should pick an apple, not "Apple Juice 64 oz".
    score -= 0.03 * Math.max(0, have.size - hits);
    if (!MULTI.test(p.name) || MULTI.test(item)) score += 0.05;
    if (!best || score > best.score) best = { p, score };
  }
  return best && best.score >= minScore ? best.p : null;
}
