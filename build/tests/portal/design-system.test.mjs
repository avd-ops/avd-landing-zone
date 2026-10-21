// The portal and the other pages in site/ use the avd-ops design system (avd-ops/avd-ops,
// docs/design-system.md), vendored in site/assets/ so the portal still contacts no other site. Tokens, fonts
// and the logo slot come from there; the portal's <style> holds only its own components.
// Run: node --test "build/tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

const root = new URL('../../../', import.meta.url).pathname;
const read = (f) => readFileSync(join(root, f), 'utf8');

test('site/assets holds a versioned copy of the avd-ops design system', () => {
  const css = read('site/assets/avd-ops.css');
  assert.match(css, /^\/\* avd-ops design system v\d+\.\d+\.\d+ \(https:\/\/avd-ops\.dev\/, (?:avd-ops|nickprignano)\/avd-ops site\/assets\/avd-ops\.css\)/);
  for (const [, src] of css.matchAll(/url\("([^"]+)"\)/g)) assert.ok(existsSync(join(root, 'site/assets', src)), src);
  assert.ok(existsSync(join(root, 'site/assets/fonts/LICENSE')), 'font licenses');
  for (const f of ['mark.svg', 'favicon.svg']) assert.ok(existsSync(join(root, 'site/assets/brand', f)), `brand/${f}`);
  // The portal components (avd-ops-portal.css) ship with the same version, so the deployment portal can move
  // onto the shared copy the assessment portal in avd-current-state also vendors.
  const portal = read('site/assets/avd-ops-portal.css');
  const v = (t, re) => (t.match(re) || [])[1];
  assert.equal(v(portal, /^\/\* avd-ops portal components (v\d+\.\d+\.\d+) /), v(css, /^\/\* avd-ops design system (v\d+\.\d+\.\d+) /), 'one version for both files');
  assert.equal(v(read('site/assets/avd-ops-shell.css'), /^\/\* avd-ops app shell (v\d+\.\d+\.\d+) /), v(css, /^\/\* avd-ops design system (v\d+\.\d+\.\d+) /), 'one version for the shell');
  assert.equal(v(read('site/assets/theme.js'), /^\/\* avd-ops theme and drawer (v\d+\.\d+\.\d+) /), v(css, /^\/\* avd-ops design system (v\d+\.\d+\.\d+) /), 'one version for theme.js');
});

// design-system.lock.json records the avd-ops tag and commit the copy came from and the hashes of its MANIFEST.json,
// so a local edit to a vendored file fails here; this repo's own styles go in the page, never in the copy.
test('the vendored files match the hashes in design-system.lock.json', () => {
  const lock = JSON.parse(read('site/assets/design-system.lock.json'));
  assert.match(lock.tag, /^ds-v\d+\.\d+\.\d+$/);
  assert.match(lock.commit, /^[0-9a-f]{40}$/);
  assert.ok(read('site/assets/avd-ops.css').startsWith(`/* avd-ops design system ${lock.tag.slice(3)} `), 'the lock names the copy\'s version');
  for (const [f, sha] of Object.entries(lock.files)) {
    assert.equal(createHash('sha256').update(readFileSync(join(root, 'site/assets', f))).digest('hex'), sha, f);
  }
});

test('the portal and the region latency page use it', () => {
  for (const f of ['site/portal/index.html', 'site/region-latency/index.html']) {
    const h = read(f);
    assert.match(h, /<link rel="stylesheet" href="\.\.\/assets\/avd-ops\.css">/, f);
    assert.match(h, /<link rel="icon" href="\.\.\/assets\/brand\/favicon\.svg"/, f);
    assert.doesNotMatch(h, /fonts\.(googleapis|gstatic)\.com|<link[^>]+href="https?:/, `${f}: no stylesheet or font from another site`);
  }
  const portal = read('site/portal/index.html');
  // The deployment portal opens in the avd-ops shell: the brand bar with the switcher (Deploy is this page) and
  // the theme button, but no side list or menu; a portal keeps its own steps and settings.
  assert.match(portal, /<body class="shell portal">/);
  // The wizard pieces (design system 2.5.0) come from avd-ops-portal.css, loaded before the shell so the bar keeps its look.
  assert.match(portal, /<link rel="stylesheet" href="\.\.\/assets\/avd-ops-portal\.css">\s*<link rel="stylesheet" href="\.\.\/assets\/avd-ops-shell\.css">\s*<script src="\.\.\/assets\/theme\.js"><\/script>/);
  const bar = (portal.match(/<header class="bar">([\s\S]*?)<\/header>/) || [])[1] || '';
  assert.match(bar, /<a class="brand" href="https:\/\/avd-ops\.dev\/"><img class="mark" src="\.\.\/assets\/brand\/mark\.svg" alt="" width="44" height="44"><span class="name"><span class="word">avd-ops<\/span><span class="tag">Deploy quietly<\/span><\/span><\/a>/, 'brand in the shell bar, as in the horizontal lockup');
  assert.match(bar, /<details class="notice"/, 'the research notice sits in the bar');
  assert.match(bar, /<a href="\.\/" aria-current="page">Deploy<\/a>/, 'Deploy is the current tool');
  assert.match(bar, /<a href="https:\/\/avd-ops\.github\.io\/avd-current-state\/portal\/">Assess<\/a>/);
  assert.match(bar, /class="iconbtn theme"/);
  assert.doesNotMatch(portal, /class="iconbtn menu"|class="side"/, 'no side list in a portal');
  assert.match(portal, /<p class="credit">A <a href="https:\/\/prignano\.ai\/">prignano\.ai<\/a> production<\/p>/);
  const style = portal.match(/<style>([\s\S]*?)<\/style>/)[1];
  assert.doesNotMatch(style, /:root|@font-face/, 'the palette and fonts come from avd-ops.css');
  assert.doesNotMatch(style, /#[0-9a-fA-F]{3,6}\b/, 'colors go through the tokens');
  const defined = new Set([...read('site/assets/avd-ops.css').matchAll(/(--[\w-]+):/g)].map((m) => m[1]));
  for (const [, v] of style.matchAll(/var\((--[\w-]+)\)/g)) assert.ok(defined.has(v), `${v} is not an avd-ops token`);
});
