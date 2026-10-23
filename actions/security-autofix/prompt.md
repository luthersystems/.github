A scheduled or manual run of the shared Security workflow failed on the
default branch. You are running as a job of that run: @RUN_URL@

The checks you are asked to fix failed: @FAILED@
(`govulncheck` is the Go vulnerability scan; `dependencies` is the
osv-scanner scan of lockfiles that are not Go's.)

The open issue labelled `security-drift` lists which checks failed. This
run is still in progress (you are one of its jobs), so its full log is not
available; reproduce the report here instead, from the repo root, with the
gate itself:

- `security-gate-govulncheck` runs the govulncheck gate exactly as the scan
  did: the same modules, the same exemptions file, binary mode included.
- `security-gate-dependencies` runs the osv-scanner gate exactly as the scan
  did: the same excludes, `osv-scanner.toml` exemptions, and fail rule (a
  High or Critical advisory with a fixed version; Go left to govulncheck).

Use these, not a plain `govulncheck ./...` or `osv-scanner`: those report
findings the gate exempts or leaves out, and you must not fix those.

FIRST, decide whether there is a real finding at all. The scheduled scan also
fails on infrastructure errors (a stalled module download, a runner that
died). If you cannot reproduce a finding, comment that on the issue and STOP.
Do not open a PR.

Do not repeat yourself. Read the drift issue's comments and the open pull
requests on `security-autofix/` branches first. If an open PR already fixes
an advisory, leave that advisory alone. If an earlier comment already
explains an advisory (major version, no upstream fix) and nothing about it
has changed, do not comment about it again. If that leaves nothing new to
do, STOP without a comment.

For each finding, classify it:

1. FIXABLE BY A PATCH OR MINOR BUMP of the same module or package.
   - Go: `go get <module>@<fixed-version>`, then `go mod tidy`. A finding in
     the Go standard library is fixed by the `toolchain` line of `go.mod`
     (and the Go of any CI image that builds the module); move it to the
     fixed patch release of the same minor version only.
   - npm: for a transitive package whose parent's range already allows the
     fixed version, `npm update <pkg> --package-lock-only --ignore-scripts`
     (the lockfile only). For a direct dependency, `npm install
     <pkg>@<fixed-version> --package-lock-only --ignore-scripts` (it also
     moves the range in package.json). Only when no parent release allows
     the fix, an `overrides` entry. yarn and pnpm: their own lockfile-only
     equivalents. uv: `uv lock --upgrade-package <pkg>`.
   - Run every package manager command except `go get` and `go mod tidy`
     through `run-untrusted` (for example `run-untrusted uv lock
     --upgrade-package <pkg>`): uv and some npm packages run downloaded
     build code to read metadata. `go get` and `go mod tidy` run no
     downloaded code and need the ssh-agent for private modules.
   - Change nothing else. Verify: build and test the affected module, and
     run EVERY build and test command through `run-untrusted`, which drops
     this job's credentials from the environment (for Go: `run-untrusted go
     build ./...`, `run-untrusted go vet ./...`, `run-untrusted go test
     ./...`; for npm: `run-untrusted npm ci --ignore-scripts`, then the
     repo's build and test scripts the same way). Then run the gate command
     again and show the finding gone.
   - Open ONE pull request for all the bumps, on a branch named
     `security-autofix/@RUN_ID@`. Its description names each advisory,
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
- Do not run install scripts (`--ignore-scripts`). Run the repo's builds
  and tests only through `run-untrusted`, and run no other downloaded code.
- Report honestly. If a verification step failed or you skipped it, say so
  in the PR or the comment.
