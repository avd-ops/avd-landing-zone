// The repository is a personal project, not for production, provided as is, and not affiliated with the author's employer.
// These notices must stay where people meet the project: the license, the README, the portal and the entry-point code.
// Run: node --test "tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../../', import.meta.url).pathname;
const read = (f) => readFileSync(root + f, 'utf8');

test('LICENSE is MIT with the as-is, no-warranty clause', () => {
  const l = read('LICENSE');
  assert.match(l, /^MIT License/);
  assert.match(l, /PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND/);
});

test('README says personal project, not for production, as is, not affiliated with the employer', () => {
  const r = read('README.md');
  const top = r.split('\n## ')[0];
  for (const re of [/Personal project/i, /Not for production/i, /Do not run it in production/i, /"as is", without warranty/i, /not affiliated with, endorsed by or supported by my employer/i, /Research and learning only/i, /forks are welcome/i]) {
    assert.match(top, re, `README intro is missing ${re}`);
  }
  assert.match(r, /## Contributing/);
  assert.match(r, /## License and disclaimer/);
});

test('the portal shows the disclaimer at the top and in the footer', () => {
  const h = read('docs/portal/index.html');
  assert.match(h, /<p class="disclaimer" id="disclaimer"><strong>Personal project, not for production\.<\/strong> Provided as is, without warranty/);
  assert.match(h, /Not affiliated with, endorsed by or supported by the author's employer/);
  assert.match(h, /<footer class="disclaimer">[^<]*without warranty[^<]*employer[^<]*Not for production use\.<\/footer>/);
});

test('entry-point code carries the notice', () => {
  const files = ['scripts/deploy/deploy.sh', 'scripts/ops/Test-AvdLandingZoneReadiness.ps1', 'scripts/ops/Deploy-AvdDemo.ps1',
    'scripts/ops/Remove-AvdDemo.ps1', 'scripts/ops/AvdLandingZone.psm1', 'scripts/automation/Invoke-AvdPowerAction.ps1',
    'bicep/main.bicep', 'bicep/demo/main.bicep', 'docs/portal/portal-core.js', 'docs/portal/report.js',
    'bicep/images/main.bicep', 'bicep/images/build.bicep', 'scripts/ops/Start-AvdImageBuild.ps1', 'scripts/ops/Connect-AvdLandingZone.ps1', 'scripts/ops/Initialize-AvdGraphApp.ps1', 'scripts/ops/ConvertFrom-AvdTargetState.ps1', 'scripts/ops/AvdTargetState.psm1', 'scripts/image/Invoke-Wdot.ps1', 'scripts/image/Test-GoldenImage.ps1'];
  for (const f of files) {
    const head = read(f).split('\n').slice(0, 5).join('\n');
    assert.match(head, /Personal project, not for production use\. Provided as is, without warranty of any kind \(MIT License, see LICENSE\)\. Not affiliated with the author's employer or with Microsoft\./, f);
  }
});
