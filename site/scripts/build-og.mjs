/**
 * Generates `public/og.png` — the card that appears when someone pastes a link
 * to this site into Slack, LinkedIn or X.
 *
 * The card is an Atelier headline card rather than a scoreboard: an eyebrow, a
 * Newsreader serif headline and the trust line, on the same paper palette the
 * marketing pages use. It used to carry the live answer count, but a number on
 * a share card invites exactly the question the number cannot answer in
 * context — and the card went stale the moment a question flipped status
 * between builds anyway. The headline does not age; the honest numbers live one
 * click away, on /proof/, where they are generated from the same roadmap file
 * as the documentation and CI.
 *
 * Pipeline: satori renders the layout to SVG with real font files, then sharp
 * rasterises it — sharp is already a dependency for `astro:assets`, so only
 * satori itself was added. Satori needs actual font binaries and does **not**
 * parse WOFF2, but the @fontsource packages ship WOFF alongside the WOFF2, so
 * the exact families the site self-hosts (Newsreader, IBM Plex Mono, Geist) are
 * read straight out of node_modules — no system-font roulette, no second copy
 * of the type in this repository.
 */

import { readFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import satori from 'satori';
import sharp from 'sharp';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');

/* --- Atelier palette (the `--ae-*` tokens in src/styles/global.css) -------- */
const PAPER = '#F3EFE4';
const INK = '#20221F';
const COPPER = '#A5623B';
const RULE = '#CDC6B7';
const VERMILION = '#C94D34';
const inkSoft = (alpha) => `rgba(32, 34, 31, ${alpha})`;

const fontFile = (pkg, file) =>
  readFileSync(resolve(root, 'node_modules/@fontsource', pkg, 'files', file));

const fonts = [
  { name: 'Newsreader', data: fontFile('newsreader', 'newsreader-latin-500-normal.woff'), weight: 500, style: 'normal' },
  { name: 'IBM Plex Mono', data: fontFile('ibm-plex-mono', 'ibm-plex-mono-latin-500-normal.woff'), weight: 500, style: 'normal' },
  { name: 'Geist', data: fontFile('geist', 'geist-latin-400-normal.woff'), weight: 400, style: 'normal' },
];

const element = {
  type: 'div',
  props: {
    style: {
      width: '1200px',
      height: '630px',
      display: 'flex',
      flexDirection: 'column',
      justifyContent: 'space-between',
      backgroundColor: PAPER,
      borderTop: `8px solid ${VERMILION}`,
      padding: '72px 80px 56px',
    },
    children: [
      // Eyebrow — mono, tracked, copper.
      {
        type: 'div',
        props: {
          style: {
            display: 'flex',
            fontFamily: 'IBM Plex Mono',
            fontWeight: 500,
            fontSize: '21px',
            letterSpacing: '0.3em',
            color: COPPER,
          },
          children: 'ENTERPRISE-READY BY INHERITANCE',
        },
      },
      // Headline + trust line, grouped above the footer rule.
      {
        type: 'div',
        props: {
          style: { display: 'flex', flexDirection: 'column' },
          children: [
            {
              type: 'div',
              props: {
                style: {
                  display: 'flex',
                  flexDirection: 'column',
                  fontFamily: 'Newsreader',
                  fontWeight: 500,
                  fontSize: '72px',
                  lineHeight: '1.16',
                  color: INK,
                },
                children: [
                  { type: 'div', props: { style: { display: 'flex' }, children: 'Say what the software must do.' } },
                  { type: 'div', props: { style: { display: 'flex' }, children: 'Let the machine do the rest.' } },
                ],
              },
            },
            {
              type: 'div',
              props: {
                style: {
                  display: 'flex',
                  flexDirection: 'column',
                  marginTop: '40px',
                  paddingTop: '28px',
                  borderTop: `1px solid ${RULE}`,
                  fontFamily: 'Geist',
                  fontSize: '26px',
                  lineHeight: '1.45',
                  color: inkSoft(0.72),
                },
                // Two manual lines: at one line the sentence overflows the
                // measure and auto-wrap orphans "CI." on its own row.
                children: [
                  {
                    type: 'div',
                    props: {
                      style: { display: 'flex' },
                      children: 'Every status is generated from the same roadmap file',
                    },
                  },
                  {
                    type: 'div',
                    props: {
                      style: { display: 'flex' },
                      children: 'used by the documentation and CI.',
                    },
                  },
                ],
              },
            },
          ],
        },
      },
      // Footer — brand and URL, mono, on the paper.
      {
        type: 'div',
        props: {
          style: {
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'baseline',
            fontFamily: 'IBM Plex Mono',
            fontWeight: 500,
            fontSize: '19px',
            letterSpacing: '0.18em',
            color: COPPER,
          },
          children: [
            { type: 'div', props: { style: { display: 'flex' }, children: 'ASH ENTERPRISE' } },
            {
              type: 'div',
              props: {
                style: { display: 'flex', letterSpacing: '0.04em', color: inkSoft(0.55) },
                children: 'lukegalea.github.io/ash_enterprise',
              },
            },
          ],
        },
      },
    ],
  },
};

const svg = await satori(element, { width: 1200, height: 630, fonts });

const out = resolve(root, 'public/og.png');
mkdirSync(dirname(out), { recursive: true });

await sharp(Buffer.from(svg)).png().toFile(out);

console.log('og: wrote public/og.png (1200x630, Atelier headline card)');
