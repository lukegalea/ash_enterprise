import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const read = (rel) => fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

const WORDS = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten',
  'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty'];

/**
 * The home page's rule: a first-party package is one of our own libraries that
 * mix.exs depends on at runtime, from git or from this repository. Test-only
 * tooling is not counted, and neither is the fork of an upstream package.
 */
const FORKS = new Set(['ash_events']);

function firstPartyPackages(mix) {
  const found = [];
  for (const [dep, name] of mix.matchAll(/\{:(\w+),\s*(?:github: "lukegalea\/\w+"|path: "[\w/]+")[^}]*\}/gs)) {
    if (FORKS.has(name) || /only:\s*\[/.test(dep)) continue;
    found.push(name);
  }
  return found;
}

test('the home page counts the first-party packages mix.exs declares', () => {
  const packages = firstPartyPackages(read('../../mix.exs'));
  const page = read('../src/pages/index.astro').replace(/\s+/g, ' ');
  const stated = page.match(/(\w+) first-party packages/)?.[1];

  assert.equal(stated, WORDS[packages.length], `mix.exs declares ${packages.length}: ${packages.join(', ')}`);
});
