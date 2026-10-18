// Text from outside this server (the team backend) is untrusted data: it is only ever shown, never followed.

/** C0/C1 controls, zero-width characters, bidi overrides and isolates, and the BOM. */
const CONTROLS = /[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u2028-\u202E\u2060-\u2069\uFEFF]/g;

/**
 * A display string from untrusted input: '' unless it is a string; controls become spaces, runs of
 * whitespace collapse to one, and the result is at most `max` characters (code points, so an emoji is
 * never split).
 */
export function cleanText(value: unknown, max: number): string {
  if (typeof value !== 'string') return '';
  const flat = value.replace(CONTROLS, ' ').replace(/\s+/g, ' ').trim();
  const chars = Array.from(flat);
  return chars.length <= max ? flat : chars.slice(0, max).join('').trim();
}

/** Like `cleanText`, but a cut lands on a word boundary and ends with "…". */
export function cleanSentence(value: unknown, max: number): string {
  const text = cleanText(value, max * 2);
  const chars = Array.from(text);
  if (chars.length <= max) return text;
  const head = chars.slice(0, max - 1).join('');
  const space = head.lastIndexOf(' ');
  return `${(space > max / 2 ? head.slice(0, space) : head).replace(/[\s,;:.]+$/, '')}…`;
}
