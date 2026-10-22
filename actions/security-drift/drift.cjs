// Opens, refreshes or closes one `security-drift` issue per repo after a
// scheduled run of the shared security workflow.
//
// Why: a scheduled scan fails with no PR to show it, and nobody watches cron
// failures. The vulnerability databases change daily, so a repo nobody has
// touched can go from clean to failing with no code change. An issue makes
// that visible and closes itself once the scan is clean again.
//
// This is luthersystems/svc's scripts/govulncheck-drift.cjs (copied into 12
// repos, label `govulncheck-drift`), widened from govulncheck to every check
// in the workflow.
//
// Inputs (env):
//   RESULTS  JSON object, check name -> job result (success, failure,
//            cancelled, skipped)
//
// Behaviour:
//   failing + no open issue -> open one
//   failing + open issue    -> comment (one issue, not one per run)
//   clean   + open issue    -> comment and close
//   clean   + no issue      -> nothing
// A cancelled check counts as failing: a scan that did not finish is not a
// clean scan, so it must not close the issue.

const LABEL = 'security-drift';
const TITLE = 'Security checks failing on main';

module.exports = async ({ github, context, core }) => {
  const results = JSON.parse(process.env.RESULTS || '{}');
  const failing = Object.entries(results)
    .filter(([, r]) => r === 'failure' || r === 'cancelled')
    .map(([name, r]) => `- \`${name}\`: ${r}`);
  const { owner, repo } = context.repo;
  const runUrl = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;

  const open = await github.rest.issues.listForRepo({ owner, repo, state: 'open', labels: LABEL });
  const existing = open.data.find((i) => !i.pull_request);

  if (failing.length === 0) {
    if (!existing) {
      core.info('All security checks passed and no drift issue is open.');
      return;
    }
    await github.rest.issues.createComment({
      owner, repo, issue_number: existing.number,
      body: `The scheduled security scan is clean as of ${runUrl}. Closing.`,
    });
    await github.rest.issues.update({
      owner, repo, issue_number: existing.number, state: 'closed', state_reason: 'completed',
    });
    core.info(`Closed #${existing.number}.`);
    return;
  }

  const body = [
    'The scheduled security scan of `main` failed these checks:',
    '',
    ...failing,
    '',
    `Run: ${runUrl}`,
    '',
    'Each check prints what it found, and how to exempt a finding, in its job log.',
    'This issue closes itself when a scheduled scan is clean.',
  ].join('\n');

  if (existing) {
    await github.rest.issues.createComment({ owner, repo, issue_number: existing.number, body });
    core.info(`Refreshed #${existing.number}.`);
    return;
  }
  const created = await github.rest.issues.create({ owner, repo, title: TITLE, body, labels: [LABEL] });
  core.info(`Opened #${created.data.number}.`);
};
