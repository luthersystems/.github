// Tests actions/security-autofix/report-failure.cjs against a fake GitHub API.
//
// Why: this report is the only signal that the auto-fix agent died. The cases
// that matter are a comment where people already look (the drift issue), and
// no pile of new issues when the fixer fails run after run.
const assert = require('node:assert/strict');
const path = require('node:path');
const run = require(path.join(__dirname, '../../actions/security-autofix/report-failure.cjs'));

function fake(driftIssues, allIssues) {
  const calls = [];
  const listForRepo = async (a) => ({ data: a.labels ? driftIssues : allIssues });
  const github = {
    paginate: async (fn, a) => (await fn(a)).data,
    rest: {
      issues: {
        listForRepo,
        create: async (a) => { calls.push(['create', a.title]); return { data: { number: 9 } }; },
        createComment: async (a) => { calls.push(['comment', a.issue_number]); return {}; },
      },
    },
  };
  const context = { repo: { owner: 'o', repo: 'r' }, serverUrl: 'https://github.com', runId: 1 };
  const core = { info: () => {} };
  return { calls, args: { github, context, core } };
}

async function check(name, driftIssues, allIssues, want) {
  const f = fake(driftIssues, allIssues);
  await run(f.args);
  assert.deepEqual(f.calls, want, name);
  console.log(`ok   autofix report: ${name}`);
}

(async () => {
  await check('comments on the open drift issue', [{ number: 3 }], [], [['comment', 3]]);
  await check('a pull request with the label is not the drift issue',
    [{ number: 4, pull_request: {} }], [], [['create', 'Security auto-fix is failing']]);
  await check('comments on its own open issue instead of opening another',
    [], [{ number: 5, title: 'Security auto-fix is failing' }], [['comment', 5]]);
  await check('opens an issue with no label, so a clean scan cannot close it',
    [], [{ number: 6, title: 'Something else' }], [['create', 'Security auto-fix is failing']]);
})().catch((e) => { console.error(e); process.exit(1); });
