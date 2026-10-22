// Tests actions/benchmark-gate/comment.cjs: the truncation contract and the
// one sticky comment, against a fake GitHub API.
//
// Why: GitHub refuses a body over 65,536 characters, so a long report must be
// cut, but never the summary (a verdict cut away is a verdict nobody reads).
// And each push must update one comment, not add another.
//
// Usage: node comment-test.cjs <big-body.md> <small-body.md>
// benchmark-test.sh writes both bodies with compare.sh: the big one has 620
// padding rows in each collapsed table, as the ~1,300-line report of elps
// PR #658 had.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const mod = require(path.join(__dirname, '../../actions/benchmark-gate/comment.cjs'));

const RUN = 'https://github.example/acme/repo/actions/runs/1234567';
const [bigPath, smallPath] = process.argv.slice(2);

function ok(name) {
  console.log(`ok   comment: ${name}`);
}

function truncation() {
  const big = fs.readFileSync(bigPath, 'utf8');
  const small = fs.readFileSync(smallPath, 'utf8');
  // Without these the cases below prove nothing.
  assert.ok(big.length > mod.BODY_LIMIT, `the big body is only ${big.length} characters`);
  assert.ok(small.length > 0 && small.length < mod.BODY_LIMIT, 'the small body is a usable control');
  ok(`the big body (${big.length} characters) is over the limit`);

  const cut = mod.truncateBody(big, RUN);
  assert.ok(cut.length <= mod.GITHUB_BODY_MAX - mod.MARKER.length - 1, `cut body is ${cut.length}`);
  assert.match(cut, /^## Benchmark comparison \(base vs PR\)/);
  assert.match(cut, /### Reviewed waivers/);
  assert.match(cut, / {2}WAIVED {6}pkg B\/op Encode-2/);
  assert.doesNotMatch(cut, /<details>/);
  assert.doesNotMatch(cut, /BenchmarkPaddingRowNumber619/);
  assert.match(cut, /This comment was truncated/);
  assert.ok(cut.includes(RUN), 'the note links the job log');
  ok(`a long body is cut to ${cut.length} characters, keeping the summary and the waivers`);

  assert.equal(mod.truncateBody(small, RUN), small);
  ok('a body within the limit is unchanged');

  // A summary that is itself over the limit (hundreds of waivers).
  let nofold = '## Benchmark comparison (base vs PR)\n\n### Reviewed waivers\n\n';
  for (let i = 0; i < 1400; i++) {
    nofold += `  WAIVED      example.com/pkg B/op BenchmarkRowNumber${String(i).padStart(5, '0')}-2 delta=+12.45% accepted: ceiling 14%\n`;
  }
  assert.ok(nofold.length > mod.BODY_LIMIT);
  const cut2 = mod.truncateBody(nofold, RUN);
  assert.ok(cut2.length <= mod.BODY_LIMIT, `cut body is ${cut2.length}`);
  assert.match(cut2, /^## Benchmark comparison/);
  assert.match(cut2, /This comment was truncated/);
  ok('a body with no collapsed section is still cut to fit, with the note');
}

function fakeGithub(comments, { failPost = false, failList = false } = {}) {
  const calls = [];
  const issues = {
    listComments: async () => ({ data: comments }),
    createComment: async (a) => {
      calls.push(['create', a.issue_number, a.body]);
      if (failPost) throw new Error('Resource not accessible by integration');
      return {};
    },
    updateComment: async (a) => {
      calls.push(['update', a.comment_id, a.body]);
      if (failPost) throw new Error('Resource not accessible by integration');
      return {};
    },
  };
  const github = {
    rest: { issues },
    paginate: async (fn, args) => {
      calls.push(['list', args.issue_number, args.per_page]);
      if (failList) throw new Error('list failed');
      return (await fn(args)).data;
    },
  };
  return { github, calls };
}

function fakeCore() {
  const log = { warning: [], info: [] };
  return { log, core: { warning: (m) => log.warning.push(m), info: (m) => log.info.push(m) } };
}

const ctx = (number) => ({
  repo: { owner: 'o', repo: 'r' },
  issue: { number },
  serverUrl: 'https://github.com',
  runId: 7,
});

const bot = { type: 'Bot' };
const human = { type: 'User' };

async function sticky() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bench-comment-'));
  const file = path.join(dir, 'body.md');
  fs.writeFileSync(file, '## Benchmark comparison (base vs PR)\nbody\n');
  process.env.BENCH_COMMENT_FILE = file;

  const cases = [
    ['no comment yet -> create', [], ['list', 'create']],
    ['our comment -> update it', [{ id: 5, user: bot, body: '<!-- luther-benchmark -->\nold' }], ['list', 'update']],
    ['a comment with the elps/substrate marker -> update it', [{ id: 6, user: bot, body: '<!-- benchmark-comparison-comment -->\nold' }], ['list', 'update']],
    ["a person's comment with the marker is not ours -> create", [{ id: 8, user: human, body: '<!-- luther-benchmark -->' }], ['list', 'create']],
    ['an unrelated bot comment -> create', [{ id: 9, user: bot, body: 'hello' }], ['list', 'create']],
  ];
  for (const [name, comments, want] of cases) {
    const f = fakeGithub(comments);
    const c = fakeCore();
    await mod({ github: f.github, context: ctx(42), core: c.core });
    assert.deepEqual(f.calls.map((x) => x[0]), want, name);
    const post = f.calls[f.calls.length - 1];
    assert.ok(post[2].startsWith('<!-- luther-benchmark -->\n## Benchmark comparison'), `${name}: body starts with the marker`);
    if (want[1] === 'update') assert.equal(post[1], comments[0].id);
    assert.equal(c.log.warning.length, 0, `${name}: no warning`);
    ok(name);
  }

  // Paginated: our comment on the second page is found, not duplicated.
  {
    const page = [];
    for (let i = 0; i < 150; i++) page.push({ id: i, user: human, body: 'x' });
    page.push({ id: 999, user: bot, body: '<!-- luther-benchmark -->' });
    const f = fakeGithub(page);
    await mod({ github: f.github, context: ctx(42), core: fakeCore().core });
    assert.deepEqual(f.calls.map((x) => x.slice(0, 2)), [['list', 42], ['update', 999]]);
    ok('the comment list is paginated, so our comment past 100 is found');
  }

  {
    const f = fakeGithub([], { failPost: true });
    const c = fakeCore();
    await mod({ github: f.github, context: ctx(42), core: c.core });
    assert.match(c.log.warning.join('\n'), /Could not post the PR comment.*expected for PRs from forks/);
    ok('a failed post is a warning, not an error (fork PRs)');
  }
  {
    const f = fakeGithub([], { failList: true });
    const c = fakeCore();
    await mod({ github: f.github, context: ctx(42), core: c.core });
    assert.deepEqual(f.calls.map((x) => x[0]), ['list', 'create']);
    assert.match(c.log.warning.join('\n'), /Could not list PR comments/);
    ok('a failed list warns and still posts');
  }
  {
    const f = fakeGithub([]);
    const c = fakeCore();
    await mod({ github: f.github, context: ctx(undefined), core: c.core });
    assert.deepEqual(f.calls, []);
    ok('not a pull request: no API call');
  }
  {
    process.env.BENCH_COMMENT_FILE = path.join(dir, 'missing.md');
    const f = fakeGithub([]);
    const c = fakeCore();
    await mod({ github: f.github, context: ctx(42), core: c.core });
    assert.deepEqual(f.calls, []);
    assert.match(c.log.warning.join('\n'), /Could not read the benchmark comment body/);
    ok('a missing body file is a warning, with no API call');
  }
  {
    delete process.env.BENCH_COMMENT_FILE;
    const c = fakeCore();
    const f = fakeGithub([]);
    await mod({ github: f.github, context: ctx(42), core: c.core });
    assert.deepEqual(f.calls, []);
    assert.match(c.log.warning.join('\n'), /BENCH_COMMENT_FILE is unset/);
    ok('no comment_file output is a warning, with no API call');
  }
  fs.rmSync(dir, { recursive: true, force: true });
}

(async () => {
  truncation();
  await sticky();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
