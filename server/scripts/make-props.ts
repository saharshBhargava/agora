// Generates placeholder prop images (400x400) deterministically. Real photos replace them later.
import sharp from 'sharp';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'assets', 'props');

const svgs: Record<string, string> = {
  // Yellow carton with a grid of white eggs.
  eggs: `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400"><rect width="400" height="400" fill="#f2c230"/>${[0, 1, 2, 3]
    .flatMap((r) => [0, 1, 2, 3, 4, 5].map((c) => `<ellipse cx="${55 + c * 58}" cy="${70 + r * 84}" rx="24" ry="32" fill="#fffaf0"/>`))
    .join('')}</svg>`,
  // Blue pack with white horizontal stripes.
  towels: `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400"><rect width="400" height="400" fill="#1f4fbf"/>${[0, 1, 2, 3, 4]
    .map((i) => `<rect x="0" y="${40 + i * 72}" width="400" height="30" fill="#f4f7ff"/>`)
    .join('')}</svg>`,
  // White carton, red band and a dark circle.
  milk: `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400"><rect width="400" height="400" fill="#f5f5f5"/><rect x="0" y="150" width="400" height="100" fill="#d62828"/><circle cx="200" cy="200" r="60" fill="#14213d"/></svg>`,
};

mkdirSync(out, { recursive: true });
for (const [name, svg] of Object.entries(svgs)) {
  await sharp(Buffer.from(svg)).jpeg({ quality: 90 }).toFile(join(out, `${name}.jpg`));
}
