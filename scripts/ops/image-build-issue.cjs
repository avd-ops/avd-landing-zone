// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
// The issue step of image-build.yml (docs/images.md), called from actions/github-script so it can be
// tested offline (build/tests/workflows/image-build-issue.test.mjs). One open failure issue at a time:
// a repeat failure comments on it, and a run that reaches Azure (built or unchanged) closes it.
'use strict';

const LABEL = 'image-build';
const NO_SUMMARY = 'Image build: failed before a summary';
const FOOTER = '\n\n---\n_Opened by image-build.yml_';
const isFailure = (title) => title === NO_SUMMARY || /^Image build \S*: failed$/.test(title);

async function ensureLabel(github, repo) {
  try { await github.rest.issues.getLabel({ ...repo, name: LABEL }); }
  catch (e) {
    if (e.status !== 404) throw e;
    await github.rest.issues.createLabel({ ...repo, name: LABEL, color: '5319e7', description: 'Golden image build results (image-build.yml)' });
  }
}

async function openFailures(github, repo) {
  const issues = await github.paginate(github.rest.issues.listForRepo, { ...repo, state: 'open', labels: LABEL, per_page: 100 });
  return issues.filter((i) => !i.pull_request && isFailure(i.title));
}

async function closeFailures(github, repo, why) {
  const closed = [];
  for (const i of await openFailures(github, repo)) {
    await github.rest.issues.createComment({ ...repo, issue_number: i.number, body: why });
    await github.rest.issues.update({ ...repo, issue_number: i.number, state: 'closed', state_reason: 'completed' });
    closed.push(i.number);
  }
  return closed;
}

// Open a failure issue, or comment on the open one with the same title instead of opening a duplicate.
async function reportFailure(github, repo, title, body, run) {
  const same = (await openFailures(github, repo)).find((i) => i.title === title);
  if (same) {
    await github.rest.issues.createComment({ ...repo, issue_number: same.number, body: `Failed again: ${run}` });
    return { commented: same.number };
  }
  const { data } = await github.rest.issues.create({ ...repo, title, labels: [LABEL], body: body + FOOTER });
  return { opened: data.number };
}

function resultBody(s, run) {
  const rows = (s.validation || []).map((v) => `| ${v.check} | ${v.status} | ${String(v.detail).replace(/\|/g, '\\|')} |`).join('\n');
  return [
    `**Status:** ${s.status}${s.emergency ? ' (emergency build)' : ''}`,
    `**Version:** \`${s.version}\` (excluded from latest until automated validation passes; spec section 6.3)`,
    `**Source image:** \`${s.sourceImageVersion}\`  **Commit:** \`${s.commit}\``,
    s.message ? `**Run status:** ${s.runState}: ${s.message}` : `**Run status:** ${s.runState}`,
    s.removedOrphans && s.removedOrphans.length ? `**Removed leftover templates:** ${s.removedOrphans.join(', ')}` : '',
    '', '### Build-time validation (Test-GoldenImage.ps1)', '',
    rows ? `| Check | Result | Detail |\n|---|---|---|\n${rows}` : '_No validation lines in the log (see the run and its artifacts)._',
    '', `Run and customization log: ${run}`
  ].join('\n');
}

// summary: the parsed image-summary.json, or null when the build stopped before writing it.
async function reportBuild({ github, context, core, summary }) {
  const repo = context.repo;
  const run = `${context.serverUrl}/${repo.owner}/${repo.repo}/actions/runs/${context.runId}`;
  await ensureLabel(github, repo);
  if (!summary) {
    return reportFailure(github, repo, NO_SUMMARY, `The build stopped before writing its summary. See the run: ${run}`, run);
  }
  if (summary.status === 'failed') {
    return reportFailure(github, repo, `Image build ${summary.version}: failed`, resultBody(summary, run), run);
  }
  const closed = await closeFailures(github, repo, `A later build reached Azure and ended ${summary.status}: ${run}. Closing.`);
  if (summary.status === 'unchanged') { core.info(`Nothing changed: ${summary.version}`); return { closed }; }
  const { data } = await github.rest.issues.create({ ...repo, title: `Image build ${summary.version}: ${summary.status}`, labels: [LABEL], body: resultBody(summary, run) + FOOTER });
  return { opened: data.number, closed };
}

// The images environment has no Azure identity yet (docs/images.md, setup): nothing ran, so a
// failure issue from an earlier unconfigured run is not a build failure. Close it.
async function closeUnconfigured({ github, context }) {
  const repo = context.repo;
  const run = `${context.serverUrl}/${repo.owner}/${repo.repo}/actions/runs/${context.runId}`;
  return { closed: await closeFailures(github, repo, `The images environment has no Azure identity configured, so the build is skipped until it is set up (docs/images.md): ${run}. Closing.`) };
}

module.exports = { reportBuild, closeUnconfigured, isFailure, NO_SUMMARY };
