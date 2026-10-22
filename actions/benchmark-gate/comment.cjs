'use strict';
// Posts, or updates, the ONE benchmark comment on a pull request. Ported from
// elps scripts/bench-comment.cjs.
//
// Two size limits, which are different things:
//   1. The report comes in a FILE named by $BENCH_COMMENT_FILE, not in an env
//      variable: on elps PR #658 a ~1,300-line report in an env variable
//      stopped the step before its script ran ("Argument list too long"),
//      although the gate had passed. See compare.sh.
//   2. GitHub refuses a comment body over 65,536 characters. truncateBody
//      cuts a long body to fit.
//
// A failed post never fails the job (for example a fork PR, whose token
// cannot write): the comment is a report, and the gate's verdict is in the
// log and the check either way.

const fs = require('fs');

// Marks this action's comment, so each push updates one comment instead of
// adding another.
const MARKER = '<!-- luther-benchmark -->';
// The marker the elps and substrate copies used. A comment with it is updated
// too, so moving to this action does not leave a second comment on open PRs.
const LEGACY_MARKERS = ['<!-- benchmark-comparison-comment -->'];

// GitHub's limit on a comment body.
const GITHUB_BODY_MAX = 65536;
// Where we cut, with room for the marker, the note and the run URL.
const BODY_LIMIT = 60000;
// Everything before the first <details> must never be cut: the heading, the
// UNMEASURABLE and NOISE-FLOOR rows and the waivers. compare.sh writes the
// body in that order; from the first <details> on are the collapsed tables.
const FOLD = '<details>';

// truncateBody(body, runUrl) -> a body that fits GITHUB_BODY_MAX. It cuts the
// collapsed tables, never the summary: a verdict lost because the table under
// it was long is a verdict nobody reads. Both cuts add the note, so a cut
// body always says so and links the full report. The second cut is for a
// summary that is itself over the limit (hundreds of waivers); the limit is
// GitHub's, so something must go.
function truncateBody(body, runUrl) {
  if (body.length <= BODY_LIMIT) {
    return body;
  }
  const note =
    "\n\n_This comment was truncated: the full report exceeded GitHub's " +
    GITHUB_BODY_MAX +
    '-character comment limit. The complete benchstat table and gate report ' +
    'are in the [job log](' +
    runUrl +
    ')._\n';
  const fold = body.indexOf(FOLD);
  let head = fold === -1 ? body : body.slice(0, fold);
  if (head.length + note.length > BODY_LIMIT) {
    head = head.slice(0, BODY_LIMIT - note.length);
  }
  return head + note;
}

// isOurs(comment) -> true for a comment a bot wrote with one of the markers.
// Only a bot's: a person who pastes the marker must not have their comment
// replaced.
function isOurs(c) {
  const body = c.body || '';
  const bot = c.user && c.user.type === 'Bot';
  return bot && [MARKER, ...LEGACY_MARKERS].some((m) => body.includes(m));
}

async function postComment({ github, context, core }) {
  const path = process.env.BENCH_COMMENT_FILE;
  if (!path) {
    core.warning('BENCH_COMMENT_FILE is unset: the compare step wrote no comment_file output, so there is no benchmark comment to post.');
    return;
  }
  const issue = context.issue && context.issue.number;
  if (!issue) {
    core.info('Not a pull request event: no benchmark comment to post.');
    return;
  }
  let body;
  try {
    body = fs.readFileSync(path, 'utf8');
  } catch (e) {
    core.warning(`Could not read the benchmark comment body from ${path}: ${e.message}`);
    return;
  }

  const { owner, repo } = context.repo;
  const runUrl = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;
  const fullBody = MARKER + '\n' + truncateBody(body, runUrl);

  let existing = null;
  try {
    // Paginated: a busy PR has more than 100 comments, and reading only the
    // first page added a second benchmark comment there.
    const comments = await github.paginate(github.rest.issues.listComments, {
      owner,
      repo,
      issue_number: issue,
      per_page: 100,
    });
    existing = comments.find(isOurs) || null;
  } catch (e) {
    core.warning(`Could not list PR comments: ${e.message}`);
  }

  try {
    if (existing) {
      await github.rest.issues.updateComment({ owner, repo, comment_id: existing.id, body: fullBody });
      core.info(`Updated the benchmark comment ${existing.id}`);
    } else {
      await github.rest.issues.createComment({ owner, repo, issue_number: issue, body: fullBody });
      core.info('Created the benchmark comment');
    }
  } catch (e) {
    core.warning(`Could not post the PR comment: ${e.message}. This is expected for PRs from forks.`);
  }
}

module.exports = postComment;
module.exports.postComment = postComment;
module.exports.truncateBody = truncateBody;
module.exports.isOurs = isOurs;
module.exports.MARKER = MARKER;
module.exports.BODY_LIMIT = BODY_LIMIT;
module.exports.GITHUB_BODY_MAX = GITHUB_BODY_MAX;
