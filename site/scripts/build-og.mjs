/**
 * Generates `public/og.png` — the card that appears when someone pastes a link
 * to this site into Slack, LinkedIn or X.
 *
 * Until this existed the layout set `twitter:card=summary_large_image` and never
 * supplied an image, so every share rendered a blank rectangle. That is a poor
 * outcome for a link whose entire job is to be pasted around.
 *
 * The card reads its numbers from `docs/roadmap.json`, the same source as every
 * status on the site. So the thing a stranger sees first is the honest
 * scoreboard rather than a slogan, and it cannot go stale while the ledger moves
 * — which is the same argument the rendered tables make, applied to the one
 * surface that is usually hand-made and forgotten.
 *
 * Rasterised with sharp, which Astro already depends on for `astro:assets`, so
 * this adds no dependency.
 */

import { readFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const roadmap = JSON.parse(readFileSync(resolve(root, '../docs/roadmap.json'), 'utf8'));

const counts = roadmap.questions.reduce((acc, q) => {
  acc[q.status] = (acc[q.status] ?? 0) + 1;
  return acc;
}, {});

const total = roadmap.questions.length;
const shipped = counts.shipped ?? 0;

// Escapes text for inclusion in SVG. Titles come from a JSON file in this
// repository rather than from user input, but a stray ampersand in a section
// title would produce an invalid document and a confusing sharp error.
const esc = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const pill = (x, label, value, colour) => `
  <g transform="translate(${x} 470)">
    <rect width="250" height="96" rx="14" fill="#111827" stroke="${colour}" stroke-opacity="0.45" />
    <text x="24" y="40" font-family="ui-sans-serif, system-ui, sans-serif" font-size="20"
          fill="#9ca3af">${esc(label)}</text>
    <text x="24" y="76" font-family="ui-sans-serif, system-ui, sans-serif" font-size="34"
          font-weight="600" fill="${colour}">${esc(value)}</text>
  </g>`;

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#0b1120" />
      <stop offset="100%" stop-color="#111c33" />
    </linearGradient>
    <radialGradient id="glow" cx="0.15" cy="0.05" r="0.8">
      <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.22" />
      <stop offset="100%" stop-color="#38bdf8" stop-opacity="0" />
    </radialGradient>
  </defs>

  <rect width="1200" height="630" fill="url(#bg)" />
  <rect width="1200" height="630" fill="url(#glow)" />
  <rect x="0" y="0" width="1200" height="6" fill="#38bdf8" />

  <text x="72" y="118" font-family="ui-monospace, SFMono-Regular, monospace" font-size="22"
        letter-spacing="3" fill="#38bdf8">ASH ENTERPRISE</text>

  <text x="72" y="212" font-family="ui-sans-serif, system-ui, sans-serif" font-size="62"
        font-weight="600" fill="#f8fafc">The cross-cutting concerns</text>
  <text x="72" y="286" font-family="ui-sans-serif, system-ui, sans-serif" font-size="62"
        font-weight="600" fill="#f8fafc">are declarable.</text>

  <text x="72" y="356" font-family="ui-sans-serif, system-ui, sans-serif" font-size="27"
        fill="#94a3b8">Ownership, hierarchy, audit, tenancy and policy —</text>
  <text x="72" y="394" font-family="ui-sans-serif, system-ui, sans-serif" font-size="27"
        fill="#94a3b8">declared once, derived everywhere.</text>

  ${pill(72, 'Answered with a test', `${shipped} of ${total}`, '#34d399')}
  ${pill(348, 'Partial, limit named', String(counts.partial ?? 0), '#fbbf24')}
  ${pill(624, 'Decided, not built', String(counts.planned ?? 0), '#38bdf8')}
  ${pill(900, 'Open, and said so', String(counts.open ?? 0), '#9ca3af')}

  <text x="72" y="600" font-family="ui-monospace, SFMono-Regular, monospace" font-size="20"
        fill="#64748b">lukegalea.github.io/ash_enterprise</text>
</svg>`;

const out = resolve(root, 'public/og.png');
mkdirSync(dirname(out), { recursive: true });

await sharp(Buffer.from(svg)).png().toFile(out);

console.log(`og: wrote public/og.png (${shipped}/${total} shipped)`);
