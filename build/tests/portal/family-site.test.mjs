// The avd-ops site moved to its own repo (avd-ops/avd-ops, https://avd-ops.dev/). The old pages here
// (site/index.html and site/family/) stay as redirects so links to avd-ops.github.io/avd-landing-zone/
// keep working, and each points at the same page on avd-ops.dev.
// Run: node --test "build/tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';

const root = new URL('../../../', import.meta.url).pathname;
const pages = ['site/index.html', ...readdirSync(join(root, 'site/family')).filter((f) => f.endsWith('.html')).map((f) => `site/family/${f}`)];
const read = (f) => readFileSync(join(root, f), 'utf8');

test('every old page of the site still exists', () => {
  for (const r of ['avd-landing-zone', 'avd-current-state', 'avd-swarm', 'avd-second-brain', 'avd-liquidware']) {
    assert.ok(pages.includes(`site/family/${r}.html`), r);
  }
});

test('every old page redirects to the same page on avd-ops.dev', () => {
  for (const f of pages) {
    const target = `https://avd-ops.dev/${f.replace(/^site\//, '').replace(/^index\.html$/, '')}`;
    const h = read(f);
    assert.ok(h.includes(`<meta http-equiv="refresh" content="0; url=${target}">`), `${f}: no refresh to ${target}`);
    assert.ok(h.includes(`<link rel="canonical" href="${target}">`), `${f}: no canonical ${target}`);
  }
});

test('relative links resolve (the portal link on each redirect page)', () => {
  for (const f of pages) {
    for (const [, href] of read(f).matchAll(/href="([^"]+)"/g)) {
      if (/^(https?:|mailto:|#)/.test(href)) continue;
      const target = join(root, dirname(f), href.split('#')[0]);
      assert.ok(existsSync(target) || existsSync(join(target, 'index.html')), `${f}: ${href}`);
    }
  }
});
