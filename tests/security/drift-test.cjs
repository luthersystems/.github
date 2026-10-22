// Tests actions/security-drift/drift.cjs against a fake GitHub API.
//
// Why: the drift issue is the only signal a failed scheduled scan leaves.
// The cases that matter are the ones that must not happen: a second issue
// for the same failure, and a cancelled scan closing an open issue as if it
// were clean.
const assert = require('node:assert/strict');
const path = require('node:path');
const run = require(path.join(__dirname, '../../actions/security-drift/drift.cjs'));

function fake(openIssues) {
  const calls = [];
  const github = {
    rest: {
      issues: {
        listForRepo: async (a) => { calls.push(['list', a.labels]); return { data: openIssues }; },
        create: async (a) => { calls.push(['create', a.title, a.labels]); return { data: { number: 9 } }; },
        createComment: async (a) => { calls.push(['comment', a.issue_number]); return {}; },
        update: async (a) => { calls.push(['update', a.issue_number, a.state]); return {}; },
      },
    },
  };
  const context = { repo: { owner: 'o', repo: 'r' }, serverUrl: 'https://github.com', runId: 1 };
  const core = { info: () => {} };
  return { calls, args: { github, context, core } };
}

async function check(name, results, openIssues, want) {
  process.env.RESULTS = JSON.stringify(results);
  const f = fake(openIssues);
  await run(f.args);
  assert.deepEqual(f.calls.slice(1).map((c) => c[0]), want, name);
  console.log(`ok   drift: ${name}`);
}

(async () => {
  await check('failure with no issue opens one', { secrets: 'failure', gosec: 'success' }, [], ['create']);
  await check('failure with an open issue comments', { secrets: 'failure' }, [{ number: 3 }], ['comment']);
  await check('clean with an open issue closes it', { secrets: 'success', gosec: 'skipped' }, [{ number: 3 }], ['comment', 'update']);
  await check('clean with no issue does nothing', { secrets: 'success' }, [], []);
  await check('a cancelled scan does not close the issue', { secrets: 'cancelled' }, [{ number: 3 }], ['comment']);
  await check('a pull request with the label is not the issue', { secrets: 'failure' }, [{ number: 4, pull_request: {} }], ['create']);
})().catch((e) => { console.error(e); process.exit(1); });
