#!/usr/bin/env node
/**
 * moat-gate.mjs — fail when private-domain terms appear in what the site
 * publishes: the synced docs, the hand-written pages and the built output.
 *
 * The terms are NOT in this repository. They arrive in the MOAT_TERMS
 * environment variable (a repository Actions secret), one case-insensitive
 * regular expression per line; blank lines and lines starting with `#` are
 * ignored. A `\b` matches at a letter/digit edge only, so `_`, `-` and `.`
 * separate words (`acme_widget` contains the word `acme`).
 *
 * With MOAT_TERMS unset or empty (forks, pull requests) the gate says so and
 * passes. A hit is reported by file and line only: the matched text and the
 * pattern are never printed, because the log of a public repository is public.
 *
 * Usage: node scripts/moat-gate.mjs   (run from site/, after `npm run build`)
 */

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE_DIR = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const ROOTS = ['src/content/docs', 'src/pages', 'src/components', 'dist'];
/** Vendored or bundled code under dist/ is not our text: the search index runtime matches on its minified source. */
const SKIP_UNDER_DIST = ['dist/pagefind', 'dist/_astro'];
const TEXT_EXT = new Set(['.md', '.mdx', '.astro', '.html', '.xml', '.txt', '.json', '.js', '.mjs', '.css', '.svg', '.ts']);

const ALNUM_BOUNDARY = '(?:(?<![A-Za-z0-9])(?=[A-Za-z0-9])|(?<=[A-Za-z0-9])(?![A-Za-z0-9]))';

export function compileTerms(raw) {
  return raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'))
    .map((line) => new RegExp(line.replace(/(?<!\\)\\b/g, () => ALNUM_BOUNDARY), 'i'));
}

async function* walk(dir) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else if (TEXT_EXT.has(path.extname(entry.name).toLowerCase())) yield full;
  }
}

async function main() {
  const raw = process.env.MOAT_TERMS ?? '';
  const terms = compileTerms(raw);
  if (terms.length === 0) {
    console.log('moat-gate: MOAT_TERMS is not set (fork or pull request); skipped.');
    return 0;
  }

  let files = 0;
  const hits = [];
  for (const root of ROOTS) {
    for await (const file of walk(path.join(SITE_DIR, root))) {
      const rel = path.relative(SITE_DIR, file).split(path.sep).join('/');
      if (SKIP_UNDER_DIST.some((dir) => rel.startsWith(`${dir}/`))) continue;
      files += 1;
      const lines = (await fs.readFile(file, 'utf8')).split('\n');
      lines.forEach((line, i) => {
        if (terms.some((re) => re.test(line))) hits.push(`${path.relative(SITE_DIR, file)}:${i + 1}`);
      });
    }
  }

  if (hits.length > 0) {
    console.error(`moat-gate: ${hits.length} line(s) in the published output match a private term:`);
    for (const hit of hits.slice(0, 200)) console.error(`  ${hit}`);
    return 1;
  }
  console.log(`moat-gate: ${terms.length} term(s), ${files} file(s) scanned, no hits.`);
  return 0;
}

process.exit(await main());
