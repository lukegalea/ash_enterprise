import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const GATE = fileURLToPath(new URL('./moat-gate.mjs', import.meta.url));
const SITE = fileURLToPath(new URL('..', import.meta.url));

const run = (terms) =>
  spawnSync(process.execPath, [GATE], {
    cwd: SITE,
    env: { ...process.env, MOAT_TERMS: terms, GITHUB_ACTIONS: '' },
    encoding: 'utf8',
  });

test('a malformed MOAT_TERMS line fails the gate and prints nothing of the line', () => {
  const result = run('# a comment\n\nzzqqterm(unclosed\n');
  const output = `${result.stdout}${result.stderr}`;

  assert.equal(result.status, 1);
  assert.match(output, /MOAT_TERMS line 3 is not a valid pattern/);
  assert.ok(!output.includes('zzqqterm'), 'the output must not contain any part of the line');
  assert.ok(!output.includes('unclosed'), 'the output must not contain the engine message');
  assert.ok(!/SyntaxError|at new RegExp/.test(output), 'no stack trace');
});

test('a well-formed term compiles and the gate reaches the scan', () => {
  const result = run('zzqqterm\\b');
  assert.notEqual(result.status, null);
  assert.ok(!/is not a valid pattern/.test(`${result.stdout}${result.stderr}`));
});
