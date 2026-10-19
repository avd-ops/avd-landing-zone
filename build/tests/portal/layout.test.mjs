// The repo is split by who it is for (README, "Repo layout"): what a person needs to deploy and run
// the landing zone at the top level, the website in site/, and how the project is built in build/.
// Release and tag archives carry only the first (.gitattributes export-ignore, releases/README.md).
// Run: node --test "build/tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';

const root = new URL('../../../', import.meta.url).pathname;
const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' });

test('a release archive holds what a user needs, and not the website or the build', () => {
  // GitHub builds a release's "Source code" zip with git archive, which honors export-ignore.
  // HEAD is the commit under test (in CI, the pull request's merge commit).
  const tar = execFileSync('git', ['archive', '--format=tar', 'HEAD'], { cwd: root, maxBuffer: 256 * 1024 * 1024 });
  const files = execFileSync('tar', ['-t'], { input: tar, maxBuffer: 64 * 1024 * 1024 }).toString().split('\n').filter(Boolean);
  for (const f of ['README.md', 'LICENSE', 'bicepconfig.json', 'bicep/main.bicep', 'parameters/dev.bicepparam', 'scripts/deploy/deploy.sh',
    'scripts/ops/Test-AvdLandingZoneReadiness.ps1', 'contracts/PINS.json', 'docs/deploy.md', 'releases/README.md']) {
    assert.ok(files.includes(f), `${f} is missing from the release archive`);
  }
  for (const f of files) assert.doesNotMatch(f, /^(build|site|\.github|\.claude|\.githooks)\//, `${f} is in the release archive`);
});

test('the website lives in site/ and the Pages workflow publishes it', () => {
  assert.ok(existsSync(root + 'site/portal/index.html'));
  assert.ok(existsSync(root + 'site/region-latency/index.html'));
  assert.match(readFileSync(root + '.github/workflows/pages.yml', 'utf8'), /upload-pages-artifact@v\d+\s+with:\s+path: site\b/);
});

test('nothing a user runs reads from site/ or build/', () => {
  // Templates and scripts must work from a release archive, which has neither folder.
  const files = git('ls-files', 'bicep', 'parameters', 'scripts').split('\n').filter(Boolean);
  for (const f of files) {
    const src = readFileSync(root + f, 'utf8');
    assert.doesNotMatch(src, /load(?:Text|Json|Yaml)Content\(\s*'[^']*(?:\.\.\/)+(?:build|site)\//, f);
    assert.doesNotMatch(src, /\$PSScriptRoot[^\n]*['"/](?:\.\.\/)+(?:build|site)\//, f);
  }
});
