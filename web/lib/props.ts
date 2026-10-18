export type PropName = 'eggs' | 'towels' | 'milk';

/** Fetches a bundled demo prop image and returns it as base64 (no data: prefix). */
export async function propBase64(name: PropName): Promise<string> {
  const res = await fetch(`/props/${name}.jpg`);
  if (!res.ok) throw new Error('Could not load the prop image');
  const bytes = new Uint8Array(await res.arrayBuffer());
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

/** "8.72", "$8", "8.5" to integer cents, or null when it is not a price. No floats. */
export function parseCents(text: string): number | null {
  const m = /^\$?(\d{1,6})(?:\.(\d{1,2}))?$/.exec(text.trim());
  if (!m) return null;
  return Number(m[1]) * 100 + Number((m[2] ?? '').padEnd(2, '0') || '0');
}
