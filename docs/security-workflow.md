# The shared security workflow

Every luthersystems repo runs the same security checks through one reusable
workflow, `.github/workflows/security.yml`. This page says what it checks,
how a repo calls it, how to exempt a finding, and how it is rolled out.

## Why it exists

An inventory of the 49 repos (October 2026) found that each repo picked its
own checks:

- govulncheck ran in 19 repos, in three versions, with five copies of the
  same scripts. Eight installed `@latest`, so one commit could pass on one
  day and fail on the next.
- No private repo had secret scanning. GitHub gives it free only to public
  repos.
- No repo scanned JS lockfiles in CI.
- A red security check blocked a merge in only four repos.

One workflow, released with this repo's tags, gives every repo the same
checks, the same tool versions and the same fail rule. A fix reaches every
repo when `v1` moves.

## What it checks

| Job | Runs when | Fails on | Exempt a finding with |
|---|---|---|---|
| `govulncheck` | the repo has a Go module | a called vulnerability (source mode on every run, binary mode too on a scheduled run) | a row in `.github/security/govulncheck-exemptions.txt` |
| `gosec` | the repo has a Go module | a gosec finding, through golangci-lint and the repo's own `.golangci.yml` | the repo's `.golangci.yml` exclusions, or `//nolint:gosec // reason` |
| `secrets` | always | a secret (key, token) in the commits a PR or push adds, or in the files at HEAD on a scheduled run | its fingerprint in `.gitleaksignore`, or the allowlist of `.gitleaks.toml` |
| `dependencies` | always (passes when there is no lockfile) | a fixable High or Critical vulnerability in a lockfile that is not Go's | an `[[IgnoredVulns]]` row in `osv-scanner.toml` |
| `result` | always | any job above that failed or was cancelled | — |

A job with nothing to scan is skipped, which counts as passed. So the one
check to require is `security / result`, in every repo.

Each tool is pinned (govulncheck v1.8.0, golangci-lint v2.15.0, gitleaks
v8.30.1, osv-scanner v2.6.0) and installed with `go install`, which checks the
module against the Go checksum database. A new tool version is a change to
this repo, reviewed once.

### The fail rule

The owner's choice (design question 4): fail on any reachable Go
vulnerability and any fixable High or Critical dependency vulnerability,
unless a reviewed exemption with an expiry date covers it.

- An expired exemption exempts nothing, so it cannot outlive its reason.
- An unfixable advisory, or a Low or Medium one, prints a warning and does not
  block: there is nothing to move to, or it is not worth stopping a merge.
  Socket and Dependabot alerts still report them.
- Go modules are left to govulncheck, which reports only code the module
  calls. osv-scanner would fail on every vulnerable module in `go.mod`.

### Not in the workflow

- **harden-check** needs the image the repo's build job just built, so repos
  that ship images keep calling `actions/harden-check` in that job.
- **Image CVE scans** (Trivy, Grype or Docker Scout) are a later step. Today
  only buildenv runs them.
- **Socket** is a GitHub App, not a workflow step. It runs on every repo it
  is installed on.

## How a repo calls it

Add `.github/workflows/security.yml` to the repo:

```yaml
name: Security

on:
  pull_request:
  push:
    branches: [main]
  schedule:
    # Private repo: weekly (Actions minutes cost money there).
    - cron: "23 6 * * 1"
    # Public repo: nightly (minutes are free). Use this line instead:
    # - cron: "23 6 * * *"
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: security-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  security:
    permissions:
      contents: read
      issues: write # the security-drift issue on scheduled runs
    uses: luthersystems/.github/.github/workflows/security.yml@v1
    # Only a repo that imports a private module (luthersystems/license):
    # secrets:
    #   SSH_PRIVATE_KEY: ${{ secrets.SSH_DEPLOY_PRIVATE_KEY }}
```

The caller's job id must be `security`, so the check is named
`security / result` in every repo.

| Input | Default | When to set it |
|---|---|---|
| `go-directories` | every `go.mod` outside `vendor/`, `testdata/`, `node_modules/` | the repo must skip a module, or scan one in such a directory |
| `govulncheck-exemptions` | `.github/security/govulncheck-exemptions.txt` | the repo keeps its exemptions elsewhere |
| `gosec` | `true` | never, unless gosec cannot type-check the repo yet |
| `osv-exclude` | none | a directory holds test lockfiles with known vulnerabilities |
| `goprivate` | `github.com/luthersystems/license` | the repo imports another private module |
| `drift-issue` | `true` | the repo tracks scheduled failures another way |
| `runs-on` | `ubuntu-latest` | the repo needs a self-hosted runner |
| `autofix` | `false` | the repo wants Claude to propose fixes for scheduled scan failures (see [Auto-fix](#auto-fix)) |
| `autofix-model` | `us.anthropic.claude-opus-5-5` | a cheaper or newer Bedrock model is wanted |

### The drift issue

A scheduled or manual run that fails opens one issue labelled
`security-drift`, comments on it at each later failure, and closes it at the
first clean run. A cancelled run counts as failed, so it never closes the
issue. This replaces the `govulncheck-drift` issues of the old per-repo
scheduled workflows.

## Auto-fix

With `autofix: true`, a scheduled or manual run of the default branch that
fails `govulncheck` or `dependencies` starts one more job, `autofix`. Claude
reads the drift issue and the failed jobs' logs, reproduces each finding by
running the gate's own scripts with the scan's inputs, and then, for each
one:

| Finding | What it does |
|---|---|
| Fixed by a patch or minor bump (Go module, Go toolchain patch, npm, yarn, pnpm, uv) | Bumps it, builds, tests, scans again, and opens one pull request for all such bumps |
| Needs a major version or a code change | Comments on the drift issue with the advisory, the call sites and a size of the work |
| No upstream fix | Comments on the drift issue |
| Not reproducible (an infrastructure failure) | Comments on the drift issue and stops |

### Why it works this way

- **It proposes, it never lands.** It opens a pull request; a person reviews
  and merges it. govulncheck reports reachable code, and the fix is often not
  a bump: ui-core's argo-workflows findings needed a v3 to v4 migration across
  23 files. The prompt stops the agent at a major version.
- **Go and lockfiles only.** A gosec finding or a leaked secret needs a
  person; a leaked secret needs rotation, not a commit.
- **Only on the default branch.** The Bedrock role admits only runs on
  `main`, and a PR's own failures belong to that PR.
- **It reproduces with the gate, not a plain scan.** A plain
  `osv-scanner` or `govulncheck ./...` reports what the gate exempts or
  leaves out, and the agent would fix those. A test fails when the agent's
  scanner pins differ from the gate's.
- **Builds and tests run without credentials in their environment.** A
  bump downloads code, and the job holds the OIDC request token, AWS
  credentials and the deploy key's ssh-agent. The agent runs builds, tests
  and package managers (but `go get` and `go mod tidy`) through
  `run-untrusted`, which keeps only an allowlist of variables. It is not a
  sandbox: code running as the same user could still read them from
  `/proc`, the ssh-agent socket or the git remote. What such code could do:
  spend on Bedrock, push a branch with the Claude App (it cannot merge past
  branch protection), and read the repos the deploy key reads. A real
  boundary (another user, or a verify job with no credentials) is a later
  step.
- **It does not repeat itself.** It reads the drift issue's comments and the
  open `security-autofix/` pull requests first, and stops without a comment
  when nothing changed.
- **It never changes `security / result`.** The job runs after `result` and
  is not in its needs. If the agent fails (turn limit, rate limit,
  timeout, or a failure before the agent starts), the job's last step
  (`actions/security-autofix-report`) comments on the drift issue, or on one
  issue labelled `security-autofix-failing` that the next finished run
  closes, so a dead fixer does not look like a quiet one. It needs `drift-issue: true`, since
  it reports there.
- **It inherits its permissions.** A job of a reusable workflow that asks
  for a permission its caller did not grant stops the whole workflow at
  startup, even when the job is skipped (probed on luthersystems/.github#13).
  So the `autofix` job asks for none: it inherits the caller's grant, and
  every scan job narrows that to `contents: read`.
  `tests/security/autofix-test.sh` fails if a job asks for more.
- **The Claude App opens the pull request**, not the job's `GITHUB_TOKEN`,
  so the pull request runs the repo's required checks.

### Turning it on

1. Install the Claude GitHub App on the repo. The Bedrock role
   (luthersystems/common-infrastructure,
   `storage/github_actions_claude_bedrock.tf`) admits a run on `main` of any
   luthersystems repo, so the repo needs no entry there.
2. In the repo's caller, add `id-token: write` to the `security` job and
   set the input:

```yaml
jobs:
  security:
    permissions:
      contents: read
      issues: write # the security-drift issue on scheduled runs
      id-token: write # auto-fix: Bedrock and the Claude App token
    uses: luthersystems/.github/.github/workflows/security.yml@v1
    with:
      autofix: true
```

`id-token: write` also applies to the caller's pull request runs, but only
the `autofix` job can use it, and that job runs only on the default branch.

To test it, run the Security workflow by hand from `main`
(`workflow_dispatch`). The `autofix` job runs only when a scan fails.

## How to exempt a finding

govulncheck, one row per advisory:

```text
# .github/security/govulncheck-exemptions.txt
# id | expires (YYYY-MM-DD) | issue | reason
GO-2026-4321 | 2026-12-31 | luthersystems/substrate#900 | stdlib fix needs Go 1.27; toolchain moves in December
```

osv-scanner, one row per advisory (either alias works):

```toml
# osv-scanner.toml
[[IgnoredVulns]]
id = "GHSA-xxxx-xxxx-xxxx"
ignoreUntil = 2026-12-31
reason = "dev-only dependency; upstream fix tracked in luthersystems/onboard#123"
```

The gate refuses a row with no `ignoreUntil` or no `reason`.

gitleaks: rotate the secret first. A false positive goes in `.gitleaksignore`
as the fingerprint the log prints (`commit:file:rule:line` for a commit,
`file:rule:line` for a scheduled scan).

## Rollout

1. Merge the workflow and release this repo (`release.yml`), which moves `v1`.
2. Add the caller to one pilot repo and fix what it finds.
3. Add the caller to every active repo, one PR per repo. Each PR removes the
   repo's own copies of the govulncheck workflows and scripts, and moves any
   exemptions (substrate's `scripts/govulncheck-exemptions.txt`) to
   `.github/security/govulncheck-exemptions.txt`.
4. In the org settings, add a ruleset that requires `security / result` on
   the default branch of every repo (design question 1). Add it after every
   repo has the caller: a required check that no workflow reports blocks
   every merge.

### The org ruleset

An org owner adds it at
<https://github.com/organizations/luthersystems/settings/rules>:

1. **New ruleset** → **New branch ruleset**.
2. **Ruleset name**: `security`. **Enforcement status**: `Active`.
3. **Bypass list**: leave it empty, so the rule holds for admins too. (Add
   `Organization admin` only if you want a break-glass merge.)
4. **Target repositories**: **All repositories**.
5. **Target branches**: **Add target** → **Include default branch**.
6. **Rules**: tick only **Require status checks to pass**. Under it:
   - **Add checks** → type `security / result`, and pick the
     **GitHub Actions** source, so another app cannot report the name.
   - Leave **Require branches to be up to date** off: the check does not
     depend on the base.
   - Tick **Do not require status checks on creation**, so a new repo can
     push its first commit (and its caller) to main.
7. **Create**.

A new repo must add the caller in its first PR; until then the ruleset
blocks every PR in it. Each repo's older per-repo govulncheck workflows can
go after the ruleset is on (one cleanup PR per repo), and a repo that lists
one of them as a required check in branch protection drops it from that
list in the same step.

## Tests

`tests/security/security-test.sh` runs each check on fixtures that must fail
and on fixtures that must pass, and asserts the reason in the log.
`tests/security/drift-test.cjs` tests the drift issue logic, and
`tests/security/osv_gate_test.py` tests how the osv gate orders versions and
finds the fix for the installed release line.
`tests/security/autofix-test.sh` tests the auto-fix prompt builder and the
permissions rule above, and `tests/security/autofix-report-test.cjs` tests
the failed-run report. The `CI`
workflow runs both, and runs each action as a caller does. The fixtures are
described in `tests/security/testdata/README.md`.
