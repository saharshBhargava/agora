// Generates detector fixture frames (640x480): an empty basket, then the eggs prop at shifting then fixed positions.
import sharp from 'sharp';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'test', 'fixtures', 'frames');
const W = 640;
const H = 480;
const SIZE = 200;

const basket = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="#6b4a2b"/>${Array.from({ length: 24 }, (_, i) => `<rect x="0" y="${i * 20}" width="${W}" height="8" fill="#7a5632"/>`).join('')}</svg>`;

mkdirSync(out, { recursive: true });
await sharp(Buffer.from(basket)).jpeg({ quality: 85 }).toFile(join(out, 'empty.jpg'));

const eggs = await sharp(join(root, 'assets', 'props', 'eggs.jpg')).resize(SIZE, SIZE).toBuffer();
const frames: [string, number, number][] = [
  ['eggs-moving1', 60, 60],
  ['eggs-moving2', 140, 110],
  ['eggs-still', 220, 180],
];
for (const [name, left, top] of frames) {
  await sharp(join(out, 'empty.jpg'))
    .composite([{ input: eggs, left, top }])
    .jpeg({ quality: 85 })
    .toFile(join(out, `${name}.jpg`));
}
