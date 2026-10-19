// The repository is written in American English: docs, script output, the portal and comments.
// Recorded real output in build/tests/portal/fixtures is left as it was captured.
// Run: node --test "build/tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const root = new URL('../../../', import.meta.url).pathname;
const SKIP = new Set(['.git', 'node_modules', 'fixtures']);
const TEXT = /\.(md|js|mjs|html|ps1|psm1|psd1|sh|bicep|bicepparam|ya?ml|json)$/;
// British spellings seen in this repository, and their common relatives.
const BRITISH = /\b(optimis|recognis|organis|summaris|authoris|prioritis|minimis|maximis|utilis|standardis|normalis|customis|initialis|finalis|visualis|categoris|analys(e|ed|es|ing)\b|licence|behaviour|colour|favour|honour|neighbour|centre|catalogue|labelled|labelling|cancelled|cancelling|modelling|travelled|defence|whilst|artefact)/i;

function walk(dir) {
  return readdirSync(dir).flatMap((n) => {
    if (SKIP.has(n)) return [];
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : TEXT.test(n) ? [p] : [];
  });
}

test('American English everywhere (outside recorded output)', () => {
  const found = [];
  for (const f of walk(root).filter((x) => !x.endsWith('spelling.test.mjs'))) {
    readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
      // aria-labelledby is the HTML attribute's spelling.
      const m = BRITISH.exec(line.replace(/aria-labelledby/g, ''));
      // "analyses" is also the plural noun; the verb is "analyzes".
      if (m && !/\banalyses\b/i.test(m[0])) found.push(`${relative(root, f)}:${i + 1}: ${m[0]}`);
    });
  }
  assert.deepEqual(found, []);
});
