// Reports an auto-fix run that did not finish (the agent hit its turn limit,
// a rate limit, an auth error or the job timeout).
//
// Why: a dead fixer looks like a quiet one. buildenv's scout-autofix died on
// a rate limit three days running and nothing said so. So the failure goes
// where people already look: the open `security-drift` issue.
//
// Why a separate issue when no drift issue is open: an issue with the
// `security-drift` label would be closed by the next clean scan, which says
// nothing about whether the fixer works.

const LABEL = 'security-drift';
const TITLE = 'Security auto-fix is failing';

module.exports = async ({ github, context, core }) => {
  const { owner, repo } = context.repo;
  const runUrl = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;
  const body = [
    `The security auto-fix run did not finish: ${runUrl}`,
    '',
    'Triage the findings by hand. The agent transcript is the run\'s',
    '`security-autofix-transcript-*` artifact.',
  ].join('\n');

  const drift = (await github.rest.issues.listForRepo({ owner, repo, state: 'open', labels: LABEL }))
    .data.find((i) => !i.pull_request);
  if (drift) {
    await github.rest.issues.createComment({ owner, repo, issue_number: drift.number, body });
    core.info(`Commented on #${drift.number}.`);
    return;
  }
  const open = await github.paginate(github.rest.issues.listForRepo, { owner, repo, state: 'open', per_page: 100 });
  const mine = open.find((i) => !i.pull_request && i.title === TITLE);
  if (mine) {
    await github.rest.issues.createComment({ owner, repo, issue_number: mine.number, body });
    core.info(`Commented on #${mine.number}.`);
    return;
  }
  const created = await github.rest.issues.create({ owner, repo, title: TITLE, body });
  core.info(`Opened #${created.data.number}.`);
};
