The scheduled run of the shared Security workflow failed on `main`: @RUN_URL@

The checks you are asked to fix failed: @FAILED@
(`govulncheck` is the Go vulnerability scan; `dependencies` is the
osv-scanner scan of lockfiles that are not Go's.)

Read the open issue labelled `security-drift` and the log of each failed
job of that run (`security / govulncheck`, `security / dependencies`) for
the report. Then reproduce it here:

- govulncheck: `govulncheck ./...` in each Go module (every `go.mod` outside
  `vendor/`, `testdata/` and `node_modules/`). Exempted advisories are in
  `@EXEMPTIONS@` when that file exists.
- dependencies: `osv-scanner scan source -r .` from the repo root. Exempted
  advisories are the `[[IgnoredVulns]]` rows of `osv-scanner.toml`. The gate
  fails only on a High or Critical advisory with a fixed version; Go modules
  are left to govulncheck.

FIRST, decide whether there is a real finding at all. The scheduled scan also
fails on infrastructure errors (a stalled module download, a runner that
died). If you cannot reproduce a finding, comment that on the issue and STOP.
Do not open a PR.

Before you open a PR, list the open PRs (`gh pr list --state open`). If one
already fixes the same advisory, comment on the issue with its link and STOP.

For each finding, classify it:

1. FIXABLE BY A PATCH OR MINOR BUMP of the same module or package.
   - Go: `go get <module>@<fixed-version>`, then `go mod tidy`. A finding in
     the Go standard library is fixed by the `toolchain` line of `go.mod`
     (and the Go of any CI image that builds the module); move it to the
     fixed patch release of the same minor version only.
   - npm: change the version in the lockfile only, with
     `npm install <pkg>@<fixed-version> --package-lock-only --ignore-scripts`
     for a direct dependency, or an `overrides` entry for a transitive one
     when its parent has no release with the fix. yarn and pnpm: the same
     with their own lockfile-only commands. pip/uv: `uv lock
     --upgrade-package <pkg>`.
   - Change nothing else. Verify: build and test the affected module (for
     Go: `go build ./...`, `go vet ./...`, `go test ./...`; for npm: `npm ci
     --ignore-scripts` then the repo's build and test scripts if it has
     them), then run the scanner again and show the finding gone.
   - Open ONE pull request for all the bumps, on a branch named
     `security-autofix/<yyyy-mm-dd>`. Its description names each advisory,
     the fixed version, the trace or path the scanner reported, and the
     verification output. Link the `security-drift` issue (do not close it;
     the next clean scan does).

2. NEEDS A MAJOR VERSION or a code change beyond a bump (the fix is only on
   a new module path such as /v3 to /v4, a new major npm release, or call
   sites must change). Do NOT attempt it. Comment on the issue with the
   advisory, why a bump cannot fix it (quote the fixed version and the path
   change), the call sites you found, and a rough size of the work. A person
   decides. This is the common case for reachable Go findings; stopping here
   is not a failure.

3. NO FIX EXISTS UPSTREAM YET. Comment on the issue with the advisory and
   the package's status. Open nothing.

A run can mix the three: open the PR for the case 1 findings and comment on
the issue about the rest.

HARD RULES:
- NEVER merge, and never push to `main`. Open the PR and stop.
- NEVER weaken the gate to make it green: do not delete or change the
  Security workflow, do not add exemptions or `IgnoredVulns` rows, do not
  narrow what is scanned, do not change govulncheck's scan mode. If the only
  way to green is a weaker check, comment and stop.
- Keep the diff minimal: bump only what carries an advisory, plus what the
  package manager needs for it. Do not upgrade unrelated dependencies.
- A bump that crosses a major version is case 2, not case 1.
- Do not run install scripts (`--ignore-scripts`) and do not run code you
  downloaded other than the repo's own build and tests.
- Report honestly. If a verification step failed or you skipped it, say so
  in the PR or the comment.
