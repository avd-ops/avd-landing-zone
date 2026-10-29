// The issue step of image-build.yml (scripts/ops/image-build-issue.cjs) against a fake GitHub API.
// Run: node --test "build/tests/workflows/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const { reportBuild, closeUnconfigured, isFailure, NO_SUMMARY } = require('../../../scripts/ops/image-build-issue.cjs');
const root = new URL('../../../', import.meta.url).pathname;

function fakeGitHub(open = [], { label = true } = {}) {
  const calls = [];
  let next = 100;
  const rec = (name, fn) => async (args) => { calls.push({ name, args }); return fn ? fn(args) : { data: {} }; };
  const github = {
    rest: {
      issues: {
        getLabel: rec('getLabel', () => { if (!label) { const e = new Error('Not Found'); e.status = 404; throw e; } return { data: {} }; }),
        createLabel: rec('createLabel'),
        listForRepo: rec('listForRepo', () => ({ data: open })),
        create: rec('create', () => ({ data: { number: next++ } })),
        createComment: rec('createComment'),
        update: rec('update')
      }
    },
    paginate: async (fn, args) => (await fn(args)).data
  };
  return { github, calls, of: (n) => calls.filter((c) => c.name === n) };
}
const context = { repo: { owner: 'o', repo: 'r' }, serverUrl: 'https://github.com', runId: 7 };
const core = { info() {} };
const summary = (status, version = '1.2.3') => ({ status, version, sourceImageVersion: 's', commit: 'c', runState: 'Succeeded', validation: [] });

test('only failure titles count as failure issues', () => {
  assert.ok(isFailure(NO_SUMMARY));
  assert.ok(isFailure('Image build 2026.11.16: failed'));
  assert.ok(isFailure('Image build : failed'));
  assert.ok(!isFailure('Image build 2026.11.16: succeeded'));
  assert.ok(!isFailure('Image build 2026.11.16: failed validation, see the run'));
});

test('no summary opens one failure issue, and creates the label when it is missing', async () => {
  const f = fakeGitHub([], { label: false });
  const r = await reportBuild({ github: f.github, context, core, summary: null });
  assert.equal(f.of('createLabel').length, 1);
  assert.equal(f.of('create').length, 1);
  assert.equal(f.of('create')[0].args.title, NO_SUMMARY);
  assert.match(f.of('create')[0].args.body, /actions\/runs\/7/);
  assert.deepEqual(r, { opened: 100 });
});

test('a repeat failure comments on the open issue instead of opening a duplicate', async () => {
  const f = fakeGitHub([{ number: 51, title: NO_SUMMARY }]);
  const r = await reportBuild({ github: f.github, context, core, summary: null });
  assert.equal(f.of('create').length, 0);
  assert.equal(f.of('createComment')[0].args.issue_number, 51);
  assert.deepEqual(r, { commented: 51 });
});

test('a failed summary opens its own issue next to a different open failure', async () => {
  const f = fakeGitHub([{ number: 51, title: NO_SUMMARY }]);
  await reportBuild({ github: f.github, context, core, summary: summary('failed') });
  assert.equal(f.of('create')[0].args.title, 'Image build 1.2.3: failed');
  assert.equal(f.of('update').length, 0);
});

test('a succeeded build closes open failure issues, never pull requests or result issues, and opens its result', async () => {
  const f = fakeGitHub([
    { number: 51, title: NO_SUMMARY },
    { number: 52, title: 'Image build 1.2.2: failed' },
    { number: 53, title: 'Image build 1.2.1: succeeded' },
    { number: 54, title: NO_SUMMARY, pull_request: {} }
  ]);
  const r = await reportBuild({ github: f.github, context, core, summary: summary('succeeded') });
  assert.deepEqual(f.of('update').map((c) => [c.args.issue_number, c.args.state, c.args.state_reason]), [[51, 'closed', 'completed'], [52, 'closed', 'completed']]);
  assert.equal(f.of('createComment').length, 2);
  assert.equal(f.of('create')[0].args.title, 'Image build 1.2.3: succeeded');
  assert.deepEqual(r, { opened: 100, closed: [51, 52] });
});

test('an unchanged build closes failure issues and opens nothing', async () => {
  const f = fakeGitHub([{ number: 51, title: NO_SUMMARY }]);
  const r = await reportBuild({ github: f.github, context, core, summary: summary('unchanged') });
  assert.equal(f.of('create').length, 0);
  assert.deepEqual(r, { closed: [51] });
});

test('an unconfigured run closes failure issues with a pointer to the setup steps', async () => {
  const f = fakeGitHub([{ number: 51, title: NO_SUMMARY }, { number: 53, title: 'Image build 1.2.1: succeeded' }]);
  const r = await closeUnconfigured({ github: f.github, context });
  assert.deepEqual(r, { closed: [51] });
  assert.match(f.of('createComment')[0].args.body, /docs\/images\.md/);
  assert.equal(f.of('create').length, 0);
});

test('the workflow skips the Azure steps until the images environment has its identity', () => {
  const wf = readFileSync(root + '.github/workflows/image-build.yml', 'utf8');
  for (const step of ['Install Bicep', "Azure login (OIDC, the images environment's identity)", 'Build']) {
    const m = wf.match(new RegExp(`- name: ${step.replace(/[()]/g, '\\$&')}\\n\\s+if: ([^\\n]+)`));
    assert.ok(m, step);
    assert.equal(m[1], "steps.setup.outputs.run == 'true'", step);
  }
  assert.match(wf, /if: steps\.setup\.outputs\.run == 'false'\n[^\n]+\n[\s\S]*?closeUnconfigured/);
  assert.match(wf, /GITHUB_STEP_SUMMARY/);
  assert.match(wf, /require\(`\$\{process\.env\.GITHUB_WORKSPACE\}\/scripts\/ops\/image-build-issue\.cjs`\)/);
});
