# The shared quality workflow

Every luthersystems repo runs the same code quality checks through one
reusable workflow, `.github/workflows/quality.yml`. This page says what it
checks, how a repo calls it, how to make an exception, and how it is rolled
out. The benchmark gate has its own workflow and page
([benchmark-workflow.md](benchmark-workflow.md)).

## Why it exists

An inventory of the local clones of all 49 repos (October 2026) found:

- Eight repos had a work marker gate, in three forks. Five were byte-for-byte
  copies of elps's (allowlist rows that expire). substrate's had moved on: a
  marker names its issue inline, and the issue must be open.
- Nineteen repos ran golangci-lint with fourteen different configs, and the
  workflows pinned versions from v2.1 to v2.15.
- Two repos (elps, substrate) had an API break gate. Both run elps's
  `cmd/apibreak` as the judge, each behind its own wrapper script. Repos with
  a public Go API that other repos import (svc, shiroclient-sdk-go,
  lutherauth-sdk-go, libmxf, insideout-terraform-presets) had none.

A fix to one copy reached no other copy. One workflow, released with this
repo's tags, gives every repo the same checks, versions and fail rule. It has
the same shape as the [security workflow](security-workflow.md): one job per
check and one `result` job to require.

## What it checks

| Job | Runs when | Fails on | Make an exception with |
|---|---|---|---|
| `work-markers` | always (input `work-markers`) | a work marker (one of five upper-case words, listed in `actions/work-markers/work-markers.sh`) that does not name an issue as `MARKER(#N)` or `MARKER(owner/repo#N)`; on a PR, a named issue that is not open | a row in `.github/quality/work-markers.txt`, only for words that are not work |
| `lint` | the repo has a Go module | a golangci-lint finding, with the repo's own `.golangci.yml` | the repo's `.golangci.yml` exclusions, or `//nolint:<linter> // reason` |
| `api-break` | a PR, when the repo sets `api-break: true` | a removed or incompatibly changed exported Go symbol (and Lisp symbol, with a surface script) | a row in `.github/quality/api-breaks.txt` |
| `result` | always | any job above that failed or was cancelled | — |

A job with nothing to check is skipped, which counts as passed. So the one
check to require is `quality / result`, in every repo.

### Why exceptions are files in the repo

The owner's choice (design question 1). Each exception is a row in a file,
with an issue and, where it can lapse, an expiry date. A reviewer sees it in
the diff, it stays in the history, and it survives a rebase. A PR label leaves
no record in git and anyone with triage access can add one. A commit trailer
is lost on a squash merge. Each gate fails on a malformed row (exit 2) and
never reads a malformed file as an empty one. A missing file means no rows,
which can only make a gate stricter.

### Work markers

The owner chose substrate's rule (design question 2). A marker is one of the
five upper-case words, standing alone. It passes when:

- it is followed at once by an issue in parentheses, `MARKER(#816)` or
  `MARKER(luthersystems/elps#850)`, where MARKER is the word; `#816` is an
  issue of the repo itself, or
- a row in the allowlist covers the line, or
- it is Go's `context.TODO()`.

On a pull request the gate reads each issue and fails unless it is open, so
a marker always points at live work. When the issue closes, the marker must
go: do the work, or point it at the issue that now tracks it. A push to the
default branch checks only that each marker names an issue, so closing an
issue does not turn main red and block a release.

The allowlist is only for words that are not work: copied third-party
source, data, a quoted message. The format is in the action
(`actions/work-markers/work-markers.sh`):

```text
# .github/quality/work-markers.txt
# path | text | expires | issue | reason
internal/protoutil/txutils.go | TODO: pick right version number | never | - | Upstream Fabric note in copied source.
```

The default token reads only the caller repo's issues. A marker that names an
issue in another private repo needs the `ISSUES_TOKEN` secret, a token that
can read that repo's issues.

### Lint

One golangci-lint version for every repo (v2.15.0, the same pin as the
security workflow's gosec job, so both jobs share one build). Each repo keeps
its own `.golangci.yml`: golangci-lint v2 cannot import a shared config, and
forcing one config would turn many repos red at once (design question 3).

The job also writes a table to the job summary: the linters the shared
baseline (`quality/golangci-baseline.yml`) enables that the repo does not,
and the linters the repo adds. This report never fails the job. The baseline
is the union of the elps and substrate sets, which shiroclient-sdk-go and
insideout-mcp already use as is. A new repo copies it as its starting point.

### API break

For a repo whose Go API other repos import. The gate compares the PR with its
base, the first parent of the PR merge commit (so commits that landed on main
after the last push do not read as the PR's changes). For each Go module it
compares every public package (not `main`, not under `internal/`) with
`apidiff`, and `cmd/apibreak` from luthersystems/elps decides. Additions never
fail. A package that does not load fails closed: an API the gate cannot read
is not a proven one.

An intended break is one row, which the gate prints ready to fill:

```text
# .github/quality/api-breaks.txt
# surface | symbol | expires | issue | reason
go | lib.Hello | 2027-01-31 | luthersystems/svc#120 | Renamed to Greet; callers move in svc v0.18.0
```

A row stays until the next release, whose notes list it, then is deleted.
For a module not at the repo root, the symbol starts with its directory
(`sub/mod/lib.Hello`), so two modules cannot share a key.

elps and substrate also guard a Lisp surface. They pass
`api-break-surface-script`, a repo script called as
`script <base-tree> <head-tree> <out-dir>` that writes `lisp-base.json` and
`lisp-head.json` (and, for elps, `golden-base/` and `golden-head/`) to
`<out-dir>`.

## How a repo calls it

Add `.github/workflows/quality.yml` to the repo:

```yaml
name: Quality

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: quality-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  quality:
    permissions:
      contents: read
      issues: read # the work marker gate reads each issue's state
    uses: luthersystems/.github/.github/workflows/quality.yml@v1
    # A repo with a public Go API:
    # with:
    #   api-break: true
    # A repo that imports a private module (luthersystems/license), or whose
    # markers name issues in other private repos:
    # secrets:
    #   SSH_PRIVATE_KEY: ${{ secrets.SSH_DEPLOY_PRIVATE_KEY }}
    #   ISSUES_TOKEN: ${{ secrets.ISSUES_READ_TOKEN }}
```

The caller's job id must be `quality`, so the check is named
`quality / result` in every repo.

| Input | Default | When to set it |
|---|---|---|
| `go-directories` | every `go.mod` outside `vendor/`, `testdata/`, `node_modules/` | the repo must skip a module |
| `work-markers` | `true` | never, unless the repo has not moved its markers yet |
| `work-markers-allowlist` | `.github/quality/work-markers.txt` | the repo keeps its allowlist elsewhere |
| `lint` | `true` | the repo lints another way |
| `golangci-lint-version` | `v2.15.0` | only for a short time, while a repo fixes the findings of a new version |
| `lint-baseline-report` | `true` | never |
| `api-break` | `false` | the repo has a public Go API |
| `api-break-directories` | the same as `go-directories` | leave out a module with no public package |
| `api-break-overrides` | `.github/quality/api-breaks.txt` | the repo keeps its overrides elsewhere |
| `api-break-exclude-deps` | none | packages that depend on a private module the gate cannot read (substrate: its license manager) |
| `api-break-surface-script` | none | elps and substrate (the Lisp surface) |
| `apibreak-version` | `v1.85.0` | never; change the default here |
| `goprivate` | `github.com/luthersystems/license` | the repo imports another private module |
| `runs-on` | `auto`: the org variable `LUTHER_CI_RUNNER` on a private repo in the runner group, else `ubuntu-latest` (see "Runners" in [security-workflow.md](security-workflow.md#runners)) | a label or a JSON array of labels, for one fixed runner |

## Rollout

1. Merge the workflow and release this repo (`release.yml`), which moves `v1`.
2. Pilot in shiroclient-sdk-go: it has the elps-style work marker gate, the
   baseline lint config and a public Go API.
3. Add the caller to every active repo, one PR per repo. Each PR removes the
   repo's own copy of each check and moves its exceptions:
   - work marker allowlist rows for deferred work become inline
     `MARKER(#N)` references; rows for words that are not work move to
     `.github/quality/work-markers.txt`;
   - `scripts/api-breaks.txt` moves to `.github/quality/api-breaks.txt`;
   - the repo's lint job and its golangci-lint version pin go.
4. In the org settings, add a ruleset that requires `quality / result` on the
   default branch of every repo, after every repo has the caller: a required
   check that no workflow reports blocks every merge.

## Tests

`tests/quality/work-markers-test.sh`, `tests/quality/golangci-lint-test.sh`
and `tests/quality/api-break-test.sh` run each gate on cases that must fail
and cases that must pass, and assert the reason in the log. The `CI`
workflow runs them, and runs each action as a caller does.
