#!/usr/bin/env node
/**
 * site-data.mjs — build the facts and code snippets the site shows, from the
 * repository itself, so no page hand-types a count or copies code.
 *
 * Writes two files under `src/data/generated/` (gitignored; `npm run data`, run by
 * `prebuild` and `dev`):
 *
 *   facts.json     counts and lists: packages (docs/packages.json), ADRs by status
 *                  (docs/adr), platform resources and domains (lib/), routes
 *                  (docs/routes.json, generated from the router by
 *                  `MIX_ENV=test mix ash_enterprise.site_routes`), the roadmap,
 *                  controls and capability ledgers, failures and test files.
 *   snippets.json  real code cut from the files `src/data/snippets.json` names.
 *
 * It exits non-zero, naming each problem, when a snippet's anchor is gone, a
 * snippet comes out empty or too long, a ledger has a shape the site cannot
 * render, or a page links an internal path without the base. The same functions
 * run in `scripts/site-data.test.mjs`, which the CI site job runs before the build.
 *
 * Usage: node scripts/site-data.mjs   (from site/)
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SITE_DIR = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
export const REPO_ROOT = path.resolve(SITE_DIR, '..');
const OUT_DIR = path.join(SITE_DIR, 'src', 'data', 'generated');
const GITHUB_BLOB = 'https://github.com/lukegalea/ash_enterprise/blob/main';

const read = (root, rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const readJson = (root, rel) => JSON.parse(read(root, rel));

function walk(dir, keep, out = []) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, keep, out);
    else if (keep(entry.name)) out.push(full);
  }
  return out.sort();
}

function tally(rows, key, keys = []) {
  const out = Object.fromEntries(keys.map((k) => [k, 0]));
  for (const row of rows) out[row[key]] = (out[row[key]] ?? 0) + 1;
  return out;
}

// ---------------------------------------------------------------------------
// ADRs
// ---------------------------------------------------------------------------

export const ADR_STATUSES = ['accepted', 'proposed', 'superseded'];

/**
 * One ADR file: its number and slug from the filename, its title from the
 * heading, and its status from the first `Status` line. `status` is the first
 * word, lowercased; `statusText` is the whole line, which carries qualifiers
 * such as "accepted, not built".
 */
export function parseAdr(filename, text) {
  const slug = filename.replace(/\.md$/, '');
  const number = slug.slice(0, 4);
  const heading = text.match(/^#\s+(?:\d+\.\s+)?ADR\s+(\d{4})\s*[—–:-]+\s*(.+)$/m);
  const statusLine = text.match(/^\s*[-*]\s*(?:\*\*Status:?\*\*:?|Status:)\s*(.+)$/m);
  const statusText = statusLine ? statusLine[1].replace(/\*\*/g, '').trim() : null;
  const status = statusText ? statusText.toLowerCase().match(/^[a-z]+/)?.[0] ?? null : null;
  return {
    number,
    slug,
    title: heading ? heading[2].trim() : null,
    headingNumber: heading ? heading[1] : null,
    status,
    statusText,
  };
}

export function readAdrs(root = REPO_ROOT) {
  const dir = path.join(root, 'docs', 'adr');
  return fs
    .readdirSync(dir)
    .filter((name) => /^\d{4}-.+\.md$/.test(name))
    .sort()
    .map((name) => parseAdr(name, fs.readFileSync(path.join(dir, name), 'utf8')));
}

export function adrProblems(adrs) {
  const problems = [];
  const seen = new Set();
  for (const adr of adrs) {
    if (seen.has(adr.number)) problems.push(`ADR ${adr.number} is numbered twice`);
    seen.add(adr.number);
    if (!adr.title) problems.push(`ADR ${adr.slug}: no "# ADR NNNN — title" heading`);
    if (adr.headingNumber && adr.headingNumber !== adr.number)
      problems.push(`ADR ${adr.slug}: heading says ${adr.headingNumber}`);
    if (!ADR_STATUSES.includes(adr.status))
      problems.push(`ADR ${adr.slug}: status ${JSON.stringify(adr.statusText)} is not one of ${ADR_STATUSES.join(', ')}`);
  }
  return problems;
}

// ---------------------------------------------------------------------------
// Resources, domains, tests
// ---------------------------------------------------------------------------

/**
 * Resources declared on the platform base: modules in lib/ whose body says `use
 * AshEnterprise.Platform.Resource` at module level (two-space indent). Not
 * counted: resources built through a macro that wraps the base (the ledger and
 * judged-field bases), dev-only modules that declare it conditionally, and
 * resources a package defines that the host only mounts. So this is a floor,
 * and the site says "declare the platform base", not "resources in total".
 */
export function platformResources(root = REPO_ROOT) {
  return platformResourceDeclarations(root).map((r) => r.module);
}

/** The base's switches a resource can turn off, each `true` unless its `use` says otherwise. */
export const BASE_OPT_OUTS = ['audit', 'archival', 'tenant'];

/**
 * The options a `use AshEnterprise.Platform.Resource` passes: the lines after it
 * indented deeper than the `use`, comments removed. Answers which of
 * BASE_OPT_OUTS it sets to `false`.
 */
export function baseOptOuts(text) {
  const lines = text.split('\n');
  const at = lines.findIndex((l) => /^  use AshEnterprise\.Platform\.Resource\b/.test(l));
  if (at < 0) return null;
  const block = [lines[at]];
  for (const line of lines.slice(at + 1)) {
    if (line.trim() !== '' && !/^ {3,}/.test(line)) break;
    block.push(line);
  }
  const options = block.map((l) => l.replace(/#.*$/, '')).join('\n');
  return BASE_OPT_OUTS.filter((flag) => new RegExp(`\\b${flag}\\?:\\s*false\\b`).test(options));
}

/** Each module of platformResources with the switches it turns off. */
export function platformResourceDeclarations(root = REPO_ROOT) {
  const declarations = [];
  for (const file of walk(path.join(root, 'lib'), (n) => n.endsWith('.ex'))) {
    const text = fs.readFileSync(file, 'utf8');
    if (!/^  use AshEnterprise\.Platform\.Resource\b/m.test(text)) continue;
    const module = text.match(/^defmodule\s+([\w.]+)\s+do/m)?.[1];
    if (module) declarations.push({ module, optOuts: baseOptOuts(text) });
  }
  return declarations.sort((a, b) => a.module.localeCompare(b.module));
}

/** Ash domains: modules in lib/ that `use Ash.Domain` at module level (the dev-only standards domain is not). */
export function domains(root = REPO_ROOT) {
  const modules = [];
  for (const file of walk(path.join(root, 'lib'), (n) => n.endsWith('.ex'))) {
    const text = fs.readFileSync(file, 'utf8');
    if (!/^  use Ash\.Domain\b(?!\.)/m.test(text)) continue;
    const name = text.match(/^defmodule\s+([\w.]+)\s+do/m)?.[1];
    if (name) modules.push(name);
  }
  return modules.sort();
}

/** ExUnit test files under test/ (the main suite; battery/ and telemetry/ have their own). */
export function testFileCount(root = REPO_ROOT) {
  return walk(path.join(root, 'test'), (n) => n.endsWith('_test.exs')).length;
}

// ---------------------------------------------------------------------------
// Ledgers
// ---------------------------------------------------------------------------

const PACKAGE_FIELDS = ['name', 'module', 'repo', 'purpose', 'used_for', 'declared', 'maturity', 'distribution', 'hex_name', 'hex_path', 'carry'];
export const MATURITIES = ['used-and-tested-here', 'wired-not-tested-here', 'tooling'];
const DECLARED = ['direct', 'transitive', 'path'];

/** Shape problems in docs/packages.json. Agreement with mix.exs and mix.lock is ExUnit's job. */
export function packageProblems(data) {
  const problems = [];
  if (!Array.isArray(data.packages) || data.packages.length === 0) return ['packages.json: no packages'];
  const names = new Set();
  for (const pkg of data.packages) {
    const at = `packages.json ${pkg.name ?? '?'}`;
    for (const field of PACKAGE_FIELDS)
      if (typeof pkg[field] !== 'string' || !pkg[field].trim()) problems.push(`${at}: ${field} missing`);
    if (names.has(pkg.name)) problems.push(`${at}: listed twice`);
    names.add(pkg.name);
    if (!MATURITIES.includes(pkg.maturity)) problems.push(`${at}: maturity ${pkg.maturity}`);
    if (!DECLARED.includes(pkg.declared)) problems.push(`${at}: declared ${pkg.declared}`);
    if (!String(pkg.distribution).startsWith('git only')) problems.push(`${at}: distribution must say git only`);
    if (pkg.declared !== 'path' && !/^[0-9a-f]{40}$/.test(pkg.ref ?? '')) problems.push(`${at}: ref is not a commit`);
    if (!/^https:\/\/github\.com\/lukegalea\//.test(pkg.repo ?? '')) problems.push(`${at}: repo is not a lukegalea GitHub URL`);
    if (pkg.adr != null && !/^\d{4}$/.test(pkg.adr)) problems.push(`${at}: adr must be four digits`);
    if (!Array.isArray(pkg.builds_on)) problems.push(`${at}: builds_on must be a list`);
    if (typeof pkg.battery !== 'boolean') problems.push(`${at}: battery must be true or false`);
  }
  for (const fork of data.forks ?? []) {
    for (const field of ['name', 'upstream', 'fork', 'ref', 'adds', 'path_back'])
      if (!fork[field]) problems.push(`packages.json fork ${fork.name ?? '?'}: ${field} missing`);
  }
  for (const override of data.overrides ?? []) {
    for (const field of ['name', 'requirement', 'reason', 'path_back'])
      if (!override[field]) problems.push(`packages.json override ${override.name ?? '?'}: ${field} missing`);
  }
  return problems;
}

export function packageFacts(data) {
  const pkgs = data.packages;
  const runtime = pkgs.filter((p) => p.maturity !== 'tooling');
  return {
    firstParty: pkgs.length,
    /** Declared in mix.exs (or a path dependency) and in a release: the home page's count. */
    runtimeDirect: runtime.filter((p) => p.declared !== 'transitive').length,
    runtime: runtime.length,
    transitive: pkgs.filter((p) => p.declared === 'transitive').length,
    tooling: pkgs.filter((p) => p.maturity === 'tooling').length,
    battery: pkgs.filter((p) => p.battery).length,
    hexNameTaken: pkgs.filter((p) => p.hex_name !== 'free').map((p) => p.name),
    byMaturity: tally(pkgs, 'maturity', MATURITIES),
    forks: (data.forks ?? []).length,
    overrides: (data.overrides ?? []).length,
  };
}

/**
 * Shape problems in docs/failures.json, and disagreement with the walkthrough's
 * table (id, title, beat). ExUnit checks the beats against the tour's code.
 */
export function failureProblems(data, walkthrough) {
  const problems = [];
  const table = new Map(
    [...walkthrough.matchAll(/^\|\s*(F\d+)\s*\|\s*(.+?)\s*\|\s*(\d+)\s*\|\s*$/gm)].map(([, id, title, beat]) => [
      id,
      { title, beat: Number(beat) },
    ]),
  );
  const ids = (data.failures ?? []).map((f) => f.id);
  const expected = Array.from({ length: 12 }, (_, i) => `F${i + 1}`);
  if (ids.join() !== expected.join()) problems.push(`failures.json: ids are ${ids.join(', ')}, expected F1 to F12 in order`);
  for (const f of data.failures ?? []) {
    const row = table.get(f.id);
    if (!row) problems.push(`failures.json ${f.id}: not in the walkthrough's table`);
    else {
      if (row.title !== f.title) problems.push(`failures.json ${f.id}: title differs from the walkthrough ("${row.title}")`);
      if (row.beat !== f.beat) problems.push(`failures.json ${f.id}: beat differs from the walkthrough (${row.beat})`);
    }
    if (typeof f.seeded !== 'boolean') problems.push(`failures.json ${f.id}: seeded must be true or false`);
    if (!f.what_happens) problems.push(`failures.json ${f.id}: what_happens missing`);
    if (!Array.isArray(f.tests) || f.tests.length === 0) problems.push(`failures.json ${f.id}: no tests cited`);
  }
  return problems;
}

export function routeFacts(data) {
  const routes = data.routes;
  return {
    total: routes.length,
    byKind: tally(routes, 'kind', ['live', 'controller', 'forward']),
    /** Signed-in LiveView screens under /app. */
    appScreens: routes.filter((r) => r.kind === 'live' && (r.path === '/app' || r.path.startsWith('/app/'))).length,
    list: routes,
  };
}

// ---------------------------------------------------------------------------
// Snippets
// ---------------------------------------------------------------------------

const DEFAULT_MAX_LINES = 30;

function dedent(lines) {
  const indents = lines.filter((l) => l.trim()).map((l) => l.match(/^ */)[0].length);
  const cut = indents.length ? Math.min(...indents) : 0;
  return lines.map((l) => l.slice(cut).trimEnd());
}

/**
 * Cut one snippet out of the repository. A spec names a `file` and one of:
 *
 *   - nothing else: the whole file;
 *   - `start` (a substring of the first line) and `end` (a substring of the last
 *     line, searched from `start`), with `endAfter` more lines if given;
 *   - `start` and `block: true`: from `start` to the next line, at the start
 *     line's indentation, that is `end` (an Elixir do-block or rule);
 *   - `json: {array, id}`: the object with that `id` in that top-level array,
 *     printed with two-space indentation.
 *
 * `mustContain` and `mustNotContain` hold the claim the page makes about the
 * code (a grant union has `authorize_if` and no `forbid_if`). Returns
 * `{snippet}` or `{error}`.
 */
export function extractSnippet(root, spec) {
  const fail = (why) => ({ error: `snippet ${spec.name} (${spec.file}): ${why}` });
  let text;
  try {
    text = read(root, spec.file);
  } catch {
    return fail('file not found');
  }
  const lines = text.split('\n');
  let first = 0;
  let last = lines.length - 1;
  let code;

  if (spec.json) {
    const rows = JSON.parse(text)[spec.json.array];
    const row = Array.isArray(rows) ? rows.find((r) => r.id === spec.json.id) : null;
    if (!row) return fail(`no ${spec.json.array} entry with id ${spec.json.id}`);
    code = JSON.stringify(row, null, 2);
    const at = lines.findIndex((l) => l.includes(`"id": "${spec.json.id}"`));
    first = Math.max(0, at - 1);
    last = first + code.split('\n').length - 1;
  } else {
    while (last > 0 && !lines[last].trim()) last -= 1;
    if (spec.start) {
      first = lines.findIndex((l) => l.includes(spec.start));
      if (first < 0) return fail(`start anchor not found: ${spec.start}`);
      if (lines.findIndex((l, i) => i > first && l.includes(spec.start)) >= 0)
        return fail(`start anchor is not unique: ${spec.start}`);
      if (spec.block) {
        const indent = lines[first].match(/^ */)[0];
        last = lines.findIndex((l, i) => i > first && l === `${indent}end`);
        if (last < 0) return fail('no closing end at the start line\'s indentation');
      } else if (spec.end) {
        last = lines.findIndex((l, i) => i >= first && l.includes(spec.end));
        if (last < 0) return fail(`end anchor not found after start: ${spec.end}`);
      } else {
        last = first;
      }
    }
    last += spec.endAfter ?? 0;
    if (last >= lines.length) return fail('endAfter runs past the end of the file');
    code = dedent(lines.slice(first, last + 1)).join('\n');
  }

  const lineCount = code.split('\n').length;
  if (!code.trim()) return fail('extracted nothing');
  if (lineCount > (spec.maxLines ?? DEFAULT_MAX_LINES))
    return fail(`${lineCount} lines, more than ${spec.maxLines ?? DEFAULT_MAX_LINES}`);
  for (const needle of spec.mustContain ?? [])
    if (!code.includes(needle)) return fail(`no longer contains ${JSON.stringify(needle)}`);
  for (const needle of spec.mustNotContain ?? [])
    if (code.includes(needle)) return fail(`now contains ${JSON.stringify(needle)}`);

  const startLine = first + 1;
  const endLine = last + 1;
  return {
    snippet: {
      name: spec.name,
      title: spec.title,
      caption: spec.caption,
      lang: spec.lang ?? (spec.file.endsWith('.json') ? 'json' : 'elixir'),
      file: spec.file,
      startLine,
      endLine,
      href: `${GITHUB_BLOB}/${spec.file}#L${startLine}-L${endLine}`,
      code,
    },
  };
}

export function extractSnippets(root, manifest) {
  const snippets = {};
  const problems = [];
  for (const spec of manifest.snippets) {
    if (!spec.name || !spec.file) {
      problems.push(`snippets.json: every snippet needs a name and a file (${JSON.stringify(spec)})`);
      continue;
    }
    if (snippets[spec.name]) problems.push(`snippets.json: ${spec.name} is named twice`);
    const { snippet, error } = extractSnippet(root, spec);
    if (error) problems.push(error);
    else snippets[spec.name] = snippet;
  }
  return { snippets, problems };
}

// ---------------------------------------------------------------------------
// Lint: internal links go through the base
// ---------------------------------------------------------------------------

/**
 * GitHub Pages serves the site under `/ash_enterprise`, so an internal href must
 * come from `withBase` (src/lib/roadmap.ts) or `import.meta.env.BASE_URL`. Flags
 * a root-relative `href`/`src` literal and a hardcoded `/ash_enterprise` string
 * in src/ (comments and the generated docs collection excepted).
 */
export function baseHrefProblems(siteDir = SITE_DIR) {
  const problems = [];
  const files = walk(path.join(siteDir, 'src'), (n) => /\.(astro|ts|mjs|js|mdx|tsx)$/.test(n)).filter(
    (f) => !f.includes(`${path.sep}content${path.sep}docs${path.sep}`) && !f.includes(`${path.sep}data${path.sep}generated${path.sep}`),
  );
  const rootRelative = /\b(?:href|src|action)=(?:"|'|\{\s*["'`])\/(?!\/)/;
  const hardcodedBase = /["'`]\/ash_enterprise(?:\/|["'`])/;
  for (const file of files) {
    const rel = path.relative(siteDir, file);
    fs.readFileSync(file, 'utf8')
      .split('\n')
      .forEach((line, i) => {
        const trimmed = line.trim();
        if (trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*')) return;
        if (rootRelative.test(line)) problems.push(`${rel}:${i + 1}: root-relative link; use withBase()`);
        if (hardcodedBase.test(line)) problems.push(`${rel}:${i + 1}: hardcoded /ash_enterprise; use withBase()`);
      });
  }
  return problems;
}

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

export function collectFacts(root = REPO_ROOT) {
  const problems = [];
  const adrs = readAdrs(root);
  problems.push(...adrProblems(adrs));

  const packages = readJson(root, 'docs/packages.json');
  problems.push(...packageProblems(packages));

  const failures = readJson(root, 'docs/failures.json');
  problems.push(...failureProblems(failures, read(root, failures.walkthrough)));

  const routes = readJson(root, 'docs/routes.json');
  if (!Array.isArray(routes.routes) || routes.routes.length === 0) problems.push('routes.json: no routes');

  const roadmap = readJson(root, 'docs/roadmap.json');
  const controls = readJson(root, 'docs/controls.json');
  const capabilities = readJson(root, 'docs/capabilities.json');
  const ROADMAP = ['shipped', 'partial', 'planned', 'open'];

  const declarations = platformResourceDeclarations(root);
  const resources = declarations.map((r) => r.module);
  if (resources.length === 0) problems.push('no resource uses AshEnterprise.Platform.Resource: the pattern is wrong');
  const domainModules = domains(root);
  if (domainModules.length === 0) problems.push('no module uses Ash.Domain: the pattern is wrong');

  const facts = {
    packages: packageFacts(packages),
    adrs: {
      total: adrs.length,
      byStatus: tally(adrs, 'status', ADR_STATUSES),
      list: adrs.map(({ number, slug, title, status, statusText }) => ({ number, slug, title, status, statusText })),
    },
    resources: {
      declaredOnBase: resources.length,
      modules: resources,
      // How many of them turn each of the base's defaults off (`audit?: false`, ...).
      optOut: Object.fromEntries(
        BASE_OPT_OUTS.map((flag) => [flag, declarations.filter((r) => r.optOuts.includes(flag)).length]),
      ),
    },
    domains: { total: domainModules.length, modules: domainModules },
    routes: routeFacts(routes),
    roadmap: {
      questions: { ...tally(roadmap.questions, 'status', ROADMAP), total: roadmap.questions.length },
      items: { ...tally(roadmap.items, 'status', ROADMAP), total: roadmap.items.length },
      sections: roadmap.sections.length,
    },
    controls: {
      frameworks: controls.frameworks.length,
      controls: controls.controls.length,
      criteria: controls.criteria.length,
      criteriaByClass: tally(controls.criteria, 'class'),
      criteriaWithEvidenceProducer: controls.criteria.filter((c) => c.evidence_producer).length,
    },
    capabilities: {
      total: capabilities.capabilities.length,
      byStatus: tally(capabilities.capabilities, 'status', ['existing', 'partial', 'missing', 'refused']),
      areas: capabilities.areas.length,
    },
    failures: {
      total: failures.failures.length,
      seeded: failures.failures.filter((f) => f.seeded).length,
    },
    tests: { files: testFileCount(root) },
  };
  return { facts, problems };
}

function main() {
  const { facts, problems } = collectFacts(REPO_ROOT);
  const manifest = JSON.parse(fs.readFileSync(path.join(SITE_DIR, 'src', 'data', 'snippets.json'), 'utf8'));
  const { snippets, problems: snippetProblems } = extractSnippets(REPO_ROOT, manifest);
  const all = [...problems, ...snippetProblems, ...baseHrefProblems(SITE_DIR)];
  if (all.length > 0) {
    console.error(`site-data: ${all.length} problem(s):`);
    for (const p of all) console.error(`  ${p}`);
    return 1;
  }
  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.writeFileSync(path.join(OUT_DIR, 'facts.json'), `${JSON.stringify(facts, null, 2)}\n`);
  fs.writeFileSync(path.join(OUT_DIR, 'snippets.json'), `${JSON.stringify(snippets, null, 2)}\n`);
  console.log(
    `site-data: ${facts.packages.firstParty} packages, ${facts.adrs.total} ADRs, ${facts.routes.total} routes, ` +
      `${Object.keys(snippets).length} snippets written to src/data/generated/.`,
  );
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
