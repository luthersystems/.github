# The shared benchmark workflow

A repo with Go benchmarks runs the benchmark regression gate through one
reusable workflow, `.github/workflows/benchmark.yml`. This page says how it
measures, how a repo calls it, how to accept a regression, and how elps and
substrate move to it.

## Why it exists

elps and substrate each ran their own gate: about 600 lines of workflow and
scripts each. The judge was already one program (`cmd/benchgate` in
luthersystems/elps, which replaced two diverged awk copies, elps#538), but
everything around it was copied: the interleaved run, the checks that the two
arms can be compared, the PR comment, the failure messages. Each repo had
fixes the other did not. elps had the GOMAXPROCS pin and the "runner unfit"
verdict; substrate had the per-benchmark sample count check, the build
failure check and the base commit fix (#654). This workflow has all of them,
once. The owner chose a full reusable workflow (design question 4), so svc
(the Handlebars engine) and libmxf can add the gate with one file.

## How it measures

| Step | Why |
|---|---|
| Check out the PR merge commit (`pr/`) and its first parent (`base/`) | The arms differ by exactly the PR's diff. `pull_request.base.sha` is stale once main moves, and then main's commits read as the PR's (substrate#654). |
| Build both with the PR's Go | The toolchain is not part of the difference. |
| Run both arms in one job, interleaved, `count` rounds | Same runner, same silicon, same thermal state. A runner that slows down part way spreads the drift over both arms, not into one. |
| Pin `GOMAXPROCS` (1 by default) | `go test` adds GOMAXPROCS to every benchmark name, and benchstat pairs rows by name. One P also makes GC work part of the timed loop, which cut the noise on allocation-heavy rows (elps#767). |
| Check samples and comparability | A dropped sample or a goos, cpu or suffix mismatch makes benchstat print a normal-looking table that compares nothing. These checks name the cause. |
| benchstat, then benchgate | A significant move in the bad direction, at or above the threshold for its metric class, fails. A row whose own spread is too wide to size the move is UNMEASURABLE: the run certified nothing (exit 3, re-run). |
| One PR comment, updated on each push | Waived, noise-floor and unmeasurable rows go above the fold, so a reviewer sees them. |

## How to accept a regression

A reviewed row in `.github/quality/benchstat-waivers.txt` (input `waivers`),
in benchgate's format, with an issue, a ceiling and an expiry. A waived row is
still measured, still shown in the PR comment, and still fails if it grows
past its ceiling. There is no label or commit trailer that skips the gate
(design question 1): the decision must stay in the repo's history. Do not
raise a threshold to accept one row; that blinds every other benchmark to the
same size of regression.

## How a repo calls it

Add `.github/workflows/benchmark.yml` to the repo:

```yaml
name: Benchmark

on:
  pull_request:

permissions:
  contents: read

concurrency:
  group: benchmark-${{ github.ref }}
  cancel-in-progress: true

jobs:
  benchmark:
    permissions:
      contents: read
      pull-requests: write # the PR comment
    uses: luthersystems/.github/.github/workflows/benchmark.yml@v1
    # A repo that imports a private module (luthersystems/license):
    # secrets:
    #   # A read-only deploy key: these jobs run on the shared luther-ci
    #   # runners, where a job from another repo could read a key.
    #   SSH_PRIVATE_KEY: ${{ secrets.LICENSE_DEPLOY_KEY }}
```

The caller's job id must be `benchmark`, so the check is named
`benchmark / result`. It passes when the gate passed, or did not need to run
(not a PR, or a PR that changes only paths `skip-paths` matches). The
measurement job is skipped, not left out, so the required check always
reports.

| Input | Default | When to set it |
|---|---|---|
| `runs-on` | `ubuntu-24.04-arm` | a label or a JSON array of labels; keep one fixed runner class |
| `timeout-minutes` | `45` | the benchmarks take longer |
| `skip-paths` | `(^docs/\|\.md$)` | other paths that cannot change a benchmark |
| `directory` | `.` | the module is not at the repo root; its `go.mod` also sets the Go |
| `go-cache` | `true` | a self-hosted runner keeps its own module cache |
| `lfs` | `false` | the benchmarks read Git LFS files |
| `packages`, `bench`, `skip`, `benchtime`, `timeout` | `./...`, `.`, none, `100ms`, `15m` | to choose what is measured |
| `count` | `10` | rarely: below 6 benchstat cannot compute an interval |
| `gomaxprocs` | `1` | the benchmarks measure contention |
| `env` | none | `KEY=VALUE` lines for `go test`; `${ARM_DIR}` is the arm's directory |
| `prepare` | none | a build the benchmarks need, run once in each arm |
| `allow-build-failures` | `false` | packages without benchmarks that CI cannot build |
| `waivers` | `.github/quality/benchstat-waivers.txt` | the repo keeps its waivers elsewhere |
| `threshold`, `alloc-threshold`, `variance-ceiling`, `alpha` | benchgate's defaults (15, 5, 30, 0.05) | the repo measured another noise floor |
| `benchgate-version` | `v1.85.0` | never; change the default here |
| `comment` | `true` | the repo does not want the PR comment |
| `goprivate` | `github.com/luthersystems/license` | the repo imports another private module |

## Moving elps and substrate

| | elps | substrate |
|---|---|---|
| Inputs | `skip: 'Parallel$'`, `timeout-minutes: 60` | `runs-on: '["self-hosted","luther-ci"]'`, `go-cache: false`, `lfs: true`, `gomaxprocs: "4"`, `threshold: "10"`, `alloc-threshold: "10"`, `prepare: make substratehcplocaltestbuild`, `env: SUBSTRATEHCP_FILE=${ARM_DIR}/cmd/substratehcp/build/substratehcp-local`, `allow-build-failures: true` |
| Waivers | move `scripts/benchstat-waivers.txt`, or set `waivers` | the same |
| Kept in the repo | the informational RunParallel job, and the self-tests of `cmd/benchgate` | the weekly baseline drift workflow (main against the last release) |

What changes for them:

- substrate's gate keeps today's verdicts only with `threshold: "10"` and
  `alloc-threshold: "10"`: its wrapper's defaults go away with the wrapper.
- benchgate is installed at a pin. elps built it from the PR tree, so an elps
  PR that changes `cmd/benchgate` was judged by its own version. Now that PR
  is checked by elps's own `cmd/benchgate` tests, and the new version reaches
  every repo when the pin here moves.
- elps gains the sample count, filter and build failure checks; substrate
  gains `pipefail` (a failing test or panic now fails the run) and the
  GOMAXPROCS suffix rule from elps#767.
- The comment marker is `<!-- luther-benchmark -->`. The old marker is found
  and updated too, so an open PR does not get a second comment.

## Tests

`tests/benchmark/benchmark-test.sh` runs every script on cases that must
fail and cases that must pass, with fake `go`, `benchstat` and `benchgate`,
and asserts the reason. `tests/benchmark/comment-test.cjs` tests the comment
truncation and the update of one comment. The `CI` workflow runs them, then
runs both actions for real on a tiny module.
