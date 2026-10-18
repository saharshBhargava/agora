/** Soft placeholder tints for product tiles (behind the photo, or alone when there is none). */
const TILES = ['#F2E3B5', '#D8E2FA', '#ECEAE6', '#F6D9CC', '#D3EDE8', '#E5DDF7'];

export function tileColor(id: string): string {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return TILES[h % TILES.length];
}

/** "Costco" from "costco". */
export function capitalize(s: string): string {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

/** "Jake's Costco run" */
export function runTitle(shopperName: string | undefined, store: string | undefined): string {
  const who = shopperName ? `${shopperName}'s` : 'The';
  return store ? `${who} ${capitalize(store)} run` : `${who} run`;
}
