import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  REPO_ROOT,
  SITE_DIR,
  baseHrefProblems,
  collectFacts,
  extractSnippet,
  extractSnippets,
  parseAdr,
} from './site-data.mjs';

const manifest = JSON.parse(fs.readFileSync(path.join(SITE_DIR, 'src/data/snippets.json'), 'utf8'));

test('the ledgers, ADRs, routes and failures have the shape the site renders', () => {
  const { facts, problems } = collectFacts(REPO_ROOT);
  assert.deepEqual(problems, []);
  assert.ok(facts.packages.firstParty > 0);
  assert.ok(facts.resources.declaredOnBase > 0);
  assert.ok(facts.domains.total > 0);
  assert.ok(facts.routes.total > 0);
  assert.equal(facts.failures.total, 12);
});

test('every snippet in src/data/snippets.json still cuts out of the source', () => {
  const { snippets, problems } = extractSnippets(REPO_ROOT, manifest);
  assert.deepEqual(problems, []);
  assert.equal(Object.keys(snippets).length, manifest.snippets.length);
  for (const s of Object.values(snippets)) {
    assert.ok(s.title && s.caption, `${s.name} needs a title and a caption`);
    assert.ok(s.code.trim().length > 0);
  }
});

test('no page links an internal path without the base', () => {
  assert.deepEqual(baseHrefProblems(SITE_DIR), []);
});

// --- the checks themselves catch what they claim to --------------------------

function fixture(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'site-data-'));
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), text);
  }
  return dir;
}

test('a snippet whose anchor is gone, or that breaks its claim, fails', () => {
  const root = fixture({
    'lib/a.ex': 'defmodule A do\n  policy X do\n    authorize_if Y\n    forbid_if Z\n  end\nend\n',
  });
  assert.match(extractSnippet(root, { name: 'n', file: 'lib/a.ex', start: 'policy Q' }).error, /start anchor not found/);
  assert.match(extractSnippet(root, { name: 'n', file: 'lib/missing.ex' }).error, /file not found/);
  assert.match(
    extractSnippet(root, { name: 'n', file: 'lib/a.ex', start: '  policy X do', block: true, mustNotContain: ['forbid_if'] }).error,
    /now contains "forbid_if"/,
  );
  assert.match(
    extractSnippet(root, { name: 'n', file: 'lib/a.ex', start: 'defmodule', block: true, maxLines: 3 }).error,
    /more than 3/,
  );
  const ok = extractSnippet(root, { name: 'n', file: 'lib/a.ex', start: '  policy X do', block: true });
  assert.equal(ok.snippet.code, 'policy X do\n  authorize_if Y\n  forbid_if Z\nend');
  assert.equal(ok.snippet.startLine, 2);
  assert.equal(ok.snippet.endLine, 5);
});

test('a JSON snippet names an entry that exists', () => {
  const root = fixture({ 'docs/c.json': '{\n  "rows": [\n    {\n      "id": "A",\n      "x": 1\n    }\n  ]\n}\n' });
  assert.match(extractSnippet(root, { name: 'n', file: 'docs/c.json', json: { array: 'rows', id: 'B' } }).error, /no rows entry/);
  assert.equal(
    extractSnippet(root, { name: 'n', file: 'docs/c.json', json: { array: 'rows', id: 'A' } }).snippet.code,
    '{\n  "id": "A",\n  "x": 1\n}',
  );
});

test('a hardcoded base or a root-relative link is reported', () => {
  const site = fixture({
    'src/pages/a.astro': '<a href="/roadmap/">x</a>\n<a href={withBase("/roadmap/")}>ok</a>\n<a href="https://x.dev/">ok</a>\n',
    'src/lib/b.ts': "const u = '/ash_enterprise/docs/';\n// '/ash_enterprise/' in a comment is fine\n",
  });
  assert.deepEqual(baseHrefProblems(site), [
    'src/lib/b.ts:1: hardcoded /ash_enterprise; use withBase()',
    'src/pages/a.astro:1: root-relative link; use withBase()',
  ]);
});

test('an ADR status is read from either status line form', () => {
  assert.equal(parseAdr('0001-x.md', '# ADR 0001 — X\n\n- **Status:** accepted, not built\n').status, 'accepted');
  assert.equal(parseAdr('0049-y.md', '# 9. ADR 0049: Y\n\n- Status: **Accepted** (2026)\n').status, 'accepted');
  assert.equal(parseAdr('0002-z.md', '# ADR 0002 — Z\n').status, null);
});
