// The portal in a real browser (run recorder spec section 13, P2): "Where did I leave off?" and
// "Record this run" on a desktop in light mode and a phone in dark mode, with no horizontal scroll
// and no console errors. Needs Playwright and Chromium; CI installs both (portal-browser job).
// Run: node --test build/tests/portal/browser
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
function playwright() {
  try { return require('playwright'); } catch { return require(join(execSync('npm root -g').toString().trim(), 'playwright')); }
}
const site = fileURLToPath(new URL('../../../../site/', import.meta.url));
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };
let server, browser, base;

before(async () => {
  server = createServer(async (req, res) => {
    const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^([/\\])+/, '');
    try { res.writeHead(200, { 'content-type': TYPES[extname(path)] || 'application/octet-stream' }).end(await readFile(join(site, path))); }
    catch { res.writeHead(404).end(); }
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}/portal/index.html`;
  const { chromium } = playwright();
  browser = await chromium.launch(process.env.PW_CHROMIUM ? { executablePath: process.env.PW_CHROMIUM } : {});
});
after(async () => { await browser?.close(); server?.close(); });

for (const [name, viewport, colorScheme] of [['desktop', { width: 1280, height: 900 }, 'light'], ['phone', { width: 390, height: 844 }, 'dark']]) {
  test(`${name}: resume and record work, with no horizontal scroll or errors`, async () => {
    const page = await browser.newPage({ viewport, colorScheme });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    await page.route(/^https?:\/\/(?!127\.0\.0\.1)/, (r) => r.abort());
    await page.goto(base);

    await page.click('#resume-link');
    assert.equal(await page.getAttribute('#resume-link', 'aria-expanded'), 'true');
    assert.match(await page.textContent('#resume-actions pre'), /Get-AvdRunStatus\.ps1/);
    await page.click('#resume-close');
    assert.ok(await page.isHidden('#resume-panel'));

    await page.click('#settings-link');
    await page.check('#record-on');
    const id = (await page.textContent('#record-id')).trim();
    assert.match(id, /^run-\d{8}-\d{4}-[a-z0-9]{4}$/);
    await page.click('#record-new');
    assert.notEqual((await page.textContent('#record-id')).trim(), id);
    const blocks = await page.locator('#record-actions pre').allTextContents();
    assert.equal(blocks.length, 5);
    for (const b of blocks) assert.match(b, /AVDLZ_RUN_ID = 'run-/);

    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false);
    // Filter out blocked third-party loads (fonts); report anything else.
    assert.deepEqual(errors.filter((e) => !/net::ERR_FAILED|Failed to load resource/.test(e)), []);
    await page.close();
  });
}
