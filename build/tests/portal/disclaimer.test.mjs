// The repository is a personal project, not for production, provided as is, and not affiliated with the author's employer.
// These notices must stay where people meet the project: the license, the README, the portal and the entry-point code.
// Run: node --test "build/tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../../../', import.meta.url).pathname;
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
  const h = read('site/portal/index.html');
  // At the top: the avd-ops shell's notice in the brand bar (design system 2.3.0), a pill that opens to the full text.
  const bar = (h.match(/<header class="bar">([\s\S]*?)<\/header>/) || [])[1] || '';
  const notice = (bar.match(/<details class="notice" id="disclaimer">([\s\S]*?)<\/details>/) || [])[1] || '';
  assert.match(notice, /<summary><strong class="long">Personal project\. Not for production\. No warranty\.<\/strong><strong class="short">Not for production<\/strong><\/summary>/);
  assert.match(notice, /<strong>Personal project, not for production\.<\/strong> Provided as is, without warranty of any kind/);
  assert.match(notice, /MIT License/);
  assert.match(notice, /Not affiliated with, endorsed by or supported by the author's employer/);
  assert.match(h, /<footer class="disclaimer">[^<]*without warranty[^<]*employer[^<]*Not for production use\.<\/footer>/);
});

test('entry-point code carries the notice', () => {
  const files = ['scripts/deploy/deploy.sh', 'scripts/deploy/Invoke-AvdControlPlanes.ps1', 'scripts/ops/Test-AvdLandingZoneReadiness.ps1', 'scripts/ops/Deploy-AvdDemo.ps1',
    'scripts/ops/Remove-AvdDemo.ps1', 'scripts/ops/Get-AvdRunStatus.ps1', 'scripts/ops/redact.mjs', 'scripts/ops/Initialize-AvdRunStore.ps1', 'scripts/ops/Start-AvdRunRecorder.ps1', 'scripts/ops/Stop-AvdRunRecorder.ps1', 'scripts/ops/AvdRunRecorder.psm1', 'bicep/recorder/main.bicep', 'bicep/recorder/store.bicep', 'scripts/ops/AvdLandingZone.psm1', 'scripts/automation/Invoke-AvdPowerAction.ps1',
    'bicep/main.bicep', 'bicep/demo/main.bicep', 'site/portal/portal-core.js', 'site/portal/report.js',
    'bicep/images/main.bicep', 'bicep/images/build.bicep', 'scripts/ops/Start-AvdImageBuild.ps1', 'scripts/ops/Connect-AvdLandingZone.ps1', 'scripts/ops/Initialize-AvdGraphApp.ps1', 'scripts/ops/ConvertFrom-AvdTargetState.ps1', 'scripts/ops/AvdTargetState.psm1', 'scripts/image/Invoke-Wdot.ps1', 'scripts/image/Test-GoldenImage.ps1', 'scripts/ops/Publish-AvdPortal.ps1', 'bicep/portal/main.bicep', 'site/portal/portal-config.js',
    'scripts/ops/AvdSpend.psm1', 'scripts/ops/AvdSandboxBatch.psm1', 'scripts/ops/Start-AvdSpendRun.ps1', 'scripts/ops/Stop-AvdSpendRun.ps1', 'scripts/ops/Set-AvdSpendBudget.ps1',
    'scripts/ops/New-AvdSandboxBatch.ps1', 'scripts/ops/Approve-AvdSandboxBatch.ps1', 'scripts/ops/Invoke-AvdSandboxBatch.ps1', 'scripts/ops/Get-AvdSandboxBatchStatus.ps1',
    'scripts/ops/Test-AvdSandboxHealth.ps1'];
  for (const f of files) {
    const head = read(f).split('\n').slice(0, 5).join('\n');
    assert.match(head, /Personal project, not for production use\. Provided as is, without warranty of any kind \(MIT License, see LICENSE\)\. Not affiliated with the author's employer or with Microsoft\./, f);
  }
});
