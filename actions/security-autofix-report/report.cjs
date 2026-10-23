// Reports whether the auto-fix run finished, in an issue people see.
//
// Why: a dead fixer looks like a quiet one. buildenv's scout-autofix died on
// a rate limit three days running and nothing said so. A run that did not
// finish (turn limit, rate limit, auth error, job timeout) is reported:
//
//   failed + open security-drift issue -> comment on it (people look there)
//   failed + no drift issue             -> open or comment on one issue
//                                          labelled security-autofix-failing
//   finished + open failing issue       -> comment and close it
//
// Why a second label, not security-drift: the next clean scan closes the
// drift issue, which says nothing about whether the fixer works. The
// failing issue closes only when a fixer run finishes.
//
// Env: STATUS, the job status (success, failure or cancelled). Anything but
// success counts as failed: a job that hits its timeout is cancelled.

const DRIFT = 'security-drift';
const FAILING = 'security-autofix-failing';
const TITLE = 'Security auto-fix is failing';

async function openIssue(github, owner, repo, label) {
  const { data } = await github.rest.issues.listForRepo({ owner, repo, state: 'open', labels: label });
  return data.find((i) => !i.pull_request);
}

module.exports = async ({ github, context, core }) => {
  const { owner, repo } = context.repo;
  const runUrl = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;
  const failing = await openIssue(github, owner, repo, FAILING);

  if (process.env.STATUS === 'success') {
    if (failing) {
      await github.rest.issues.createComment({
        owner, repo, issue_number: failing.number,
        body: `The security auto-fix run finished: ${runUrl}. Closing.`,
      });
      await github.rest.issues.update({
        owner, repo, issue_number: failing.number, state: 'closed', state_reason: 'completed',
      });
      core.info(`Closed #${failing.number}.`);
    }
    return;
  }

  const body = [
    `The security auto-fix run did not finish: ${runUrl}`,
    '',
    "Triage the findings by hand. The agent transcript is the run's",
    '`security-autofix-transcript-*` artifact.',
  ].join('\n');
  const target = (await openIssue(github, owner, repo, DRIFT)) || failing;
  if (target) {
    await github.rest.issues.createComment({ owner, repo, issue_number: target.number, body });
    core.info(`Commented on #${target.number}.`);
    return;
  }
  const created = await github.rest.issues.create({ owner, repo, title: TITLE, body, labels: [FAILING] });
  core.info(`Opened #${created.data.number}.`);
};
