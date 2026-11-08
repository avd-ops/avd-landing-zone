// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
// The issue step of image-build.yml (docs/images.md), called from actions/github-script so it can be
// tested offline (build/tests/workflows/image-build-issue.test.mjs). One open failure issue at a time:
// a new failure comments on it with its report, and a succeeded build closes it.
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

async function closeFailures(github, repo, why, which) {
  const closed = [];
  for (const i of (await openFailures(github, repo)).filter(which)) {
    await github.rest.issues.createComment({ ...repo, issue_number: i.number, body: why });
    await github.rest.issues.update({ ...repo, issue_number: i.number, state: 'closed', state_reason: 'completed' });
    closed.push(i.number);
  }
  return closed;
}

// One open failure issue at a time: a new failure adds its full report to the open one.
async function reportFailure(github, repo, title, body) {
  const open = (await openFailures(github, repo))[0];
  if (open) {
    await github.rest.issues.createComment({ ...repo, issue_number: open.number, body: `**Failed again** (${title}):\n\n${body}` });
    return { commented: open.number };
  }
  const { data } = await github.rest.issues.create({ ...repo, title, labels: [LABEL], body: body + FOOTER });
  return { opened: data.number };
}

function resultBody(s, run) {
  const rows = (s.validation || []).map((v) => `| ${v.check} | ${v.status} | ${String(v.detail).replace(/\\/g, '\\\\').replace(/\|/g, '\\|')} |`).join('\n');
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

const runUrl = (context) => `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;

// summary: the parsed image-summary.json, or null when the build stopped before writing it.
// Only a succeeded build closes failure issues. Any summary at all means the run signed in to Azure,
// so it closes a "failed before a summary" issue; "unchanged" proves nothing about an earlier failed version.
async function reportBuild({ github, context, core, summary }) {
  const repo = context.repo;
  const run = runUrl(context);
  await ensureLabel(github, repo);
  if (!summary) {
    return reportFailure(github, repo, NO_SUMMARY, `The build stopped before writing its summary. See the run: ${run}`);
  }
  if (summary.status === 'failed') {
    return reportFailure(github, repo, `Image build ${summary.version}: failed`, resultBody(summary, run));
  }
  const closed = await closeFailures(github, repo, `A later build ended ${summary.status}: ${run}. Closing.`,
    (i) => summary.status === 'succeeded' || i.title === NO_SUMMARY);
  if (summary.status === 'unchanged') { core.info(`Nothing changed: ${summary.version}`); return { closed }; }
  const { data } = await github.rest.issues.create({ ...repo, title: `Image build ${summary.version}: ${summary.status}`, labels: [LABEL], body: resultBody(summary, run) + FOOTER });
  return { opened: data.number, closed };
}

// The images environment has no Azure identity yet (docs/images.md, setup): nothing ran. A
// "failed before a summary" issue is what an unconfigured run leaves, so close it; a failed
// version's issue came from a configured run and stays open.
async function closeUnconfigured({ github, context }) {
  const closed = await closeFailures(github, context.repo,
    `The images environment has no Azure identity configured, so scheduled builds are skipped until it is set up (docs/images.md): ${runUrl(context)}. Closing.`,
    (i) => i.title === NO_SUMMARY);
  return { closed };
}

module.exports = { reportBuild, closeUnconfigured, isFailure, NO_SUMMARY };
