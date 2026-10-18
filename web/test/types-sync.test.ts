// @vitest-environment node
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test } from 'vitest';

const read = (rel: string) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

test('web/lib/types.ts matches server/src/types.ts (run pnpm -C web sync-types)', () => {
  expect(read('../lib/types.ts')).toBe(read('../../server/src/types.ts'));
});
