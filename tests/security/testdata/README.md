# Security check fixtures

Inputs for `tests/security/security-test.sh` and the `security-actions` CI
job. They hold known vulnerabilities on purpose, so each check can be shown
to fail as well as pass.

| Fixture | What it holds |
|---|---|
| `go-vuln` | Calls `language.ParseAcceptLanguage` in `golang.org/x/text` v0.3.7 (GO-2022-1059, fixed in v0.3.8). |
| `go-clean` | A module with no dependencies. |
| `go-gosec` | Runs a command its caller names, which gosec reports as G204. |
| `iac-misconfig` | A Dockerfile with no `USER`, which Trivy reports as DS-0002 (High). |
| `sast-vuln` | Runs user input through a shell, which Semgrep reports as `subprocess-shell-true` (ERROR, security, MEDIUM confidence). |
| `npm-vuln` | A lockfile with `lodash` 4.17.15 and `minimist` 1.2.5, which have fixable High and Critical advisories. |

They live under `testdata/` so the workflow's own module detection skips
them, and this repo's own security scan excludes this directory. No fixture
holds a secret: the gitleaks test builds its fake key at run time, because a
key-shaped string in a commit would trip GitHub push protection on this
public repo.
