// Tests actions/security-autofix-report/report.cjs against a fake GitHub API.
//
// Why: this report is the only signal that the auto-fix agent died. The cases
// that matter are a comment where people already look (the drift issue), no
// pile of new issues when the fixer fails run after run, and no stale
// report once the fixer works again.
const assert = require('node:assert/strict');
const path = require('node:path');
const run = require(path.join(__dirname, '../../actions/security-autofix-report/report.cjs'));

function fake(byLabel) {
  const calls = [];
  const github = {
    rest: {
      issues: {
        listForRepo: async (a) => ({ data: byLabel[a.labels] || [] }),
        create: async (a) => { calls.push(['create', a.labels.join()]); return { data: { number: 9 } }; },
        createComment: async (a) => { calls.push(['comment', a.issue_number]); return {}; },
        update: async (a) => { calls.push(['close', a.issue_number]); return {}; },
      },
    },
  };
  const context = { repo: { owner: 'o', repo: 'r' }, serverUrl: 'https://github.com', runId: 1 };
  const core = { info: () => {} };
  return { calls, args: { github, context, core } };
}

async function check(name, outcome, byLabel, want) {
  process.env.STATUS = outcome;
  const f = fake(byLabel);
  await run(f.args);
  assert.deepEqual(f.calls, want, name);
  console.log(`ok   autofix report: ${name}`);
}

const drift = { 'security-drift': [{ number: 3 }] };
const failing = { 'security-autofix-failing': [{ number: 5 }] };
(async () => {
  await check('a failed run comments on the drift issue', 'failure', drift, [['comment', 3]]);
  await check('a pull request with the label is not the drift issue', 'failure',
    { 'security-drift': [{ number: 4, pull_request: {} }] }, [['create', 'security-autofix-failing']]);
  await check('a failed run comments on its open failing issue', 'failure', failing, [['comment', 5]]);
  await check('a failed run with no issue opens one, not labelled security-drift', 'failure', {},
    [['create', 'security-autofix-failing']]);
  await check('a finished run closes the failing issue', 'success', { ...drift, ...failing },
    [['comment', 5], ['close', 5]]);
  await check('a finished run with no failing issue does nothing', 'success', drift, []);
  await check('a cancelled (timed out) run is reported', 'cancelled', drift, [['comment', 3]]);
})().catch((e) => { console.error(e); process.exit(1); });
