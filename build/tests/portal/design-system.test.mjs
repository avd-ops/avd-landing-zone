// The portal and the other pages in site/ use the avd-ops design system (avd-ops/avd-ops,
// docs/design-system.md), vendored in site/assets/ so the portal still contacts no other site. Tokens, fonts
// and the logo slot come from there; the portal's <style> holds only its own components.
// Run: node --test "build/tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('../../../', import.meta.url).pathname;
const read = (f) => readFileSync(join(root, f), 'utf8');

test('site/assets holds a versioned copy of the avd-ops design system', () => {
  const css = read('site/assets/avd-ops.css');
  assert.match(css, /^\/\* avd-ops design system v\d+\.\d+\.\d+ \(https:\/\/avd-ops\.dev\/, avd-ops\/avd-ops site\/assets\/avd-ops\.css\)/);
  for (const [, src] of css.matchAll(/url\("([^"]+)"\)/g)) assert.ok(existsSync(join(root, 'site/assets', src)), src);
  assert.ok(existsSync(join(root, 'site/assets/fonts/LICENSE')), 'font licenses');
  for (const f of ['mark.svg', 'favicon.svg']) assert.ok(existsSync(join(root, 'site/assets/brand', f)), `brand/${f}`);
  // The portal components (avd-ops-portal.css) ship with the same version, so the deployment portal can move
  // onto the shared copy the assessment portal in avd-current-state also vendors.
  const portal = read('site/assets/avd-ops-portal.css');
  const v = (t, re) => (t.match(re) || [])[1];
  assert.equal(v(portal, /^\/\* avd-ops portal components (v\d+\.\d+\.\d+) /), v(css, /^\/\* avd-ops design system (v\d+\.\d+\.\d+) /), 'one version for both files');
});

test('the portal and the region latency page use it', () => {
  for (const f of ['site/portal/index.html', 'site/region-latency/index.html']) {
    const h = read(f);
    assert.match(h, /<link rel="stylesheet" href="\.\.\/assets\/avd-ops\.css">/, f);
    assert.match(h, /<link rel="icon" href="\.\.\/assets\/brand\/favicon\.svg"/, f);
    assert.doesNotMatch(h, /fonts\.(googleapis|gstatic)\.com|<link[^>]+href="https?:/, `${f}: no stylesheet or font from another site`);
  }
  const portal = read('site/portal/index.html');
  assert.match(portal, /<a class="home" href="https:\/\/avd-ops\.dev\/"><img class="mark" src="\.\.\/assets\/brand\/mark\.svg" alt=""[^>]*>avd-ops<\/a>/, 'logo slot in the top bar');
  const style = portal.match(/<style>([\s\S]*?)<\/style>/)[1];
  assert.doesNotMatch(style, /:root|@font-face/, 'the palette and fonts come from avd-ops.css');
  assert.doesNotMatch(style, /#[0-9a-fA-F]{3,6}\b/, 'colors go through the tokens');
  const defined = new Set([...read('site/assets/avd-ops.css').matchAll(/(--[\w-]+):/g)].map((m) => m[1]));
  for (const [, v] of style.matchAll(/var\((--[\w-]+)\)/g)) assert.ok(defined.has(v), `${v} is not an avd-ops token`);
});
