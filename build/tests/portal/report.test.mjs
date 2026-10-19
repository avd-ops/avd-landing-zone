// Tests for the portal's issue reports (site/portal/report.js): redaction and the GitHub link.
// Run: node --test "build/tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';

const require = createRequire(import.meta.url);
const R = require('../../../site/portal/report.js');
const P = require('../../../site/portal/portal-core.js');
const root = new URL('../../../', import.meta.url).pathname;
const fixture = (name) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
const fixtures = readdirSync(new URL('./fixtures/', import.meta.url)).filter((f) => f.endsWith('.txt'));

// Every private value in fixtures/pii-sample.txt. None may survive redaction.
const PRIVATE = [
  'jdoe', 'JDoe', 'jane.doe', 'fabrikam.com', 'fabrikamcorp', 'jane_gmail', 'Fabrikam Production', 'Fabrikam AVD Users', 'Fabrikam AVD Admins',
  '3f2a1b4c-1111-2222-3333-444455556666', '7d8e9f00-aaaa-bbbb-cccc-ddddeeeeffff', 'fabstdevq2w3e4r5', 'stfabdevq2w3e4r5', 'kvfabdevq2w3e4r5t6',
  '20.51.3.4', 'QWERTY123', 'Hunter2', 'Zm9vYmFy', 'AbCdEf123', 'eyJhbGci', 'abcDEF123', "'fab-dev'", '"namePrefix":"fab"'
];

test('redact: removes every private value in the sample', () => {
  const r = R.redact(fixture('pii-sample.txt'));
  for (const v of PRIVATE) assert.ok(!r.text.includes(v), `still contains ${v}`);
  assert.ok(r.total > 20);
});

test('redact: keeps what diagnosis needs', () => {
  const t = R.redact(fixture('pii-sample.txt')).text;
  for (const v of ['9cdead84-a844-4324-93f2-b2e6bb768d07', '10.100.2.9', 'privatelink.file.core.windows.net', 'parameters/dev.bicepparam', 'eastus2', 'https://microsoft.com/devicelogin', 'Test-AvdLandingZoneReadiness.ps1'])
    assert.ok(t.includes(v), `lost ${v}`);
});

test('redact: the same value always gets the same placeholder', () => {
  const t = R.redact(fixture('pii-sample.txt')).text;
  const caller = /Caller (\S+) can deploy/.exec(t)[1];
  assert.match(caller, /^<email-\d+>$/);
  assert.match(t, new RegExp(`Azure: ${caller};`));
  const sub = /in '(<subscription-\d+>)' \(FIX mode\)/.exec(t)[1];
  assert.ok(t.includes(`"subscription":"${sub}"`));
});

test('redact: extra terms and settings', () => {
  const r = R.redact('Contact Acme Widgets at the Springfield office; prefix acm, group Acme AVD Users; acmex stays', {
    extraTerms: ['Springfield', 'acme widgets'], known: [{ kind: 'name', value: 'acm' }, { kind: 'name', value: 'Acme AVD Users' }, { kind: 'name', value: 'avdlz' }]
  });
  assert.equal(r.text, 'Contact <custom-1> at the <custom-2> office; prefix <name-2>, group <name-1>; acmex stays');
});

test('redact: running it again finds nothing new and keeps numbering', () => {
  const once = R.redact(fixture('pii-sample.txt')).text;
  const twice = R.redact(once);
  assert.equal(twice.text, once);
  assert.equal(twice.total, 0);
  // New values in an edited report are numbered after the old ones.
  assert.match(R.redact(once + '\nalso bob@fabrikam.org').text, /also <email-4>$/);
});

test('redact: every fixture keeps the analysis the portal made of it', () => {
  for (const f of fixtures) {
    const text = fixture(f);
    const a = P.analyze(text, {}), b = P.analyze(R.redact(text).text, {});
    assert.equal(b.recognized, a.recognized, f);
    assert.equal(b.source, a.source, f);
    assert.equal(b.stage, a.stage, f);
    assert.equal(b.status, a.status, f);
    assert.equal(b.step, a.step, f);
    assert.deepEqual(b.failures.map((x) => x.id || x.check.replace(/<[a-z]+-\d+>/g, '')).length, a.failures.length, f);
    assert.deepEqual(b.problems.map((x) => x.id), a.problems.map((x) => x.id), f);
    assert.equal(P.extractStates(R.redact(text).text).filter((s) => s.parseError).length, 0, `${f}: state line no longer parses`);
  }
});

test('redact: the committed fixtures have nothing left to find except the placeholder tenant', () => {
  for (const f of fixtures.filter((x) => x !== 'pii-sample.txt')) {
    const r = R.redact(fixture(f));
    // The real runs were redacted by hand to contoso.com UPNs, placeholder IDs and the default
    // subscription name; anything else found here is a value that slipped through.
    for (const k of Object.keys(r.counts)) assert.ok(['email', 'id', 'user', 'storage', 'vault', 'subscription'].includes(k), `${f}: found ${k}`);
  }
});

// A GUID in the templates, parameter files or scripts must be the same in every tenant (a tenant's
// own IDs come from environment variables), and it must stay readable in a report.
function walk(dir) {
  return readdirSync(dir).flatMap((n) => { const p = join(dir, n); return statSync(p).isDirectory() ? walk(p) : [p]; });
}
test('PUBLIC_IDS lists every GUID in bicep/, parameters/ and scripts/', () => {
  const found = new Set();
  for (const f of ['bicep', 'parameters', 'scripts'].flatMap((d) => walk(join(root, d))))
    for (const m of readFileSync(f, 'utf8').matchAll(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi)) found.add(m[0].toLowerCase());
  const missing = [...found].filter((g) => !R.PUBLIC_IDS.includes(g));
  assert.deepEqual(missing, [], 'add these to PUBLIC_IDS in site/portal/report.js (only if they are the same in every tenant)');
});

test('buildReport: redacts the description and settings too, and fences the output safely', () => {
  const analysis = P.analyze(fixture('pii-sample.txt'), {});
  const rep = R.buildReport({
    output: fixture('pii-sample.txt') + '\n```\n## not a heading',
    description: 'Jane (jane.doe@fabrikam.com) ran it at Fabrikam HQ',
    analysis, step: 'predeploy', config: { namePrefix: 'fab', usersGroup: 'Fabrikam AVD Users', location: 'eastus2', parameterFile: 'parameters/dev.bicepparam' },
    extraTerms: ['Fabrikam HQ']
  });
  for (const v of PRIVATE) assert.ok(!rep.body.includes(v) && !rep.title.includes(v), `still contains ${v}`);
  assert.ok(!rep.body.includes('Fabrikam HQ'));
  assert.match(rep.body, /^### What happened/);
  assert.match(rep.body, /- Findings: lz-missing/);
  assert.match(rep.body, /\n````text\n/);
  assert.match(rep.body, /<!-- avdlz-portal-report v1 -->/);
  assert.match(rep.title, /^Portal: Pre-deployment preflight: Not ready/);
});

test('buildReport: works without pasted output', () => {
  const rep = R.buildReport({ description: 'The latency test never finishes', step: 'region' });
  assert.match(rep.body, /The latency test never finishes/);
  assert.ok(!rep.body.includes('### Cloud Shell output'));
  assert.equal(rep.title, 'Portal: problem at step region');
});

test('issueUrl: short reports go whole; long ones keep the start and the state line', () => {
  const repo = 'https://github.com/nickprignano/avd-landing-zone';
  const small = R.issueUrl(repo, 'T', 'body');
  assert.equal(small.trimmed, 0);
  assert.ok(small.url.startsWith(repo + '/issues/new?labels=portal-report&title=T&body='));

  const filler = Array.from({ length: 400 }, (_, i) => `  [PASS ] check number ${i} passed with some detail text`).join('\n');
  const body = '### What happened\n\nIt broke\n\n' + filler + '\n<<<AVDLZ-STATE {"v":1,"stage":"postdeploy","status":"ready"} AVDLZ-STATE>>>';
  const long = R.issueUrl(repo, 'T', body);
  assert.ok(long.trimmed > 0);
  assert.ok(long.url.length <= 7500, `url is ${long.url.length}`);
  const sent = decodeURIComponent(long.url.split('&body=')[1]);
  assert.match(sent, /^### What happened\n\nIt broke/);
  assert.match(sent, /lines cut to fit a GitHub link/);
  assert.match(sent, /AVDLZ-STATE>>>$/);
});

test('redact: the launch link IDs and names in a post-deployment state line (decision 0014)', () => {
  // An adopter's own prefix (the repo default, avdlz, is public and kept).
  const t = R.redact(fixture('state-postdeploy-ready-launch.txt').replace(/avdlz/g, 'fabx')).text;
  for (const v of ['a0a0a0a0-0000-4000-8000-000000000001', 'b0b0b0b0-0000-4000-8000-000000000001', '55555555-5555-5555-5555-555555555555', 'fabx'])
    assert.ok(!t.includes(v), `still contains ${v}`);
  assert.match(t, /"launch":\{"workspaceObjectId":"<id-\d+>"/);
});
