import { copyFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const src = fileURLToPath(new URL('../../server/src/types.ts', import.meta.url));
const dst = fileURLToPath(new URL('../lib/types.ts', import.meta.url));
copyFileSync(src, dst);
console.log(`synced ${src} -> ${dst}`);
