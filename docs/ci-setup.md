# CI & Code Quality

## GitHub Actions

Four workflows are included in `.github/workflows/` (configured with immutable commit-SHA action pins and least-privilege token permissions):

| Workflow | Trigger | Checks |
|----------|---------|--------|
| `branch-protection.yml` | Push/PR to `development`, `main` | Parallel gates: local-only file detection & `.gitattributes` & Bats skip-count ratchet (`validate`); ShellCheck, shfmt format, snippet lint & command verification (`lint`); parallelized 2-batch matrix (`test: [fast, slow]`); aggregate required status check (`all-gates-green`). |
| `docs-validation.yml` | Push to `development`/`main` or a PR that changes `*.md` files (except `CLAUDE.md`, `MEMORY.md`) | Markdown linting (`markdownlint-cli2`, blocking), spelling of `README.md`, `skill/`, `command/` (`typos`, blocking), broken link validation (`lychee`, advisory). |
| `nightly.yml` | Scheduled (weekly Sundays 03:00 UTC) / manual dispatch | Cross-platform full test suite (`ubuntu-latest` + `windows-latest`), complete documentation link audit, and tooling/snippet drift canary. |
| `release.yml` | Tag push matching `v*` | Creates GitHub Release with auto-generated notes and source archives with scoped `contents: write`. |
| `.github/dependabot.yml` | Scheduled monthly | Automated dependency and commit-SHA updates for GitHub Actions. |

---

## CI Verification Gate

CGW doesn't stop at "push succeeded" — every push it performs (direct push, a merge's
target push, a PR, or a tagged release) is followed by `scripts/git/verify_ci.sh`, which
resolves the pushed commit from the remote, waits for the GitHub Actions runs it triggered to
register and finish, and prints one verdict line:

```bash
./scripts/git/verify_ci.sh --branch development   # CI: green <sha> (0) / CI: red <workflow> <url> (1)
./scripts/git/verify_ci.sh --pr 42 --sha <sha>    # CI: unverified -- <reason> (2) / CI: not applicable (3)
```

Exit `3` is the silent no-op case (no `gh` CLI, no auth, no GitHub remote, no active workflow,
or `CGW_CI_VERIFY=0`). Agents fix-and-retry on exit `1` and report exit `2` as unverified
rather than green — the procedure is in
[`skill/references/ci-verification.md`](../skill/references/ci-verification.md).

Knobs (`.cgw.conf` or environment — see [`configuration.md`](configuration.md)):
`CGW_CI_VERIFY` (`0` disables the gate), `CGW_CI_TIMEOUT_SECONDS` (`--timeout`),
`CGW_CI_POLL_INTERVAL` (`--poll`), `CGW_CI_REQUIRED_WORKFLOWS` (comma-separated), and the
agent-facing `CGW_CI_MAX_FIX_ROUNDS`.

---

## Charlie CI Agent

This project uses [Charlie](https://charlielabs.ai) for AI-assisted code review on pull requests.

```yaml
# .charlie/config.yml
checkCommands:
  fix: shfmt -w -i 2 -ci scripts/   # auto-format after edits
  lint: shellcheck -x --severity=error --source-path=scripts/git scripts/git/*.sh  # static analysis
```

**Setup** (repository admin): Install the `charliecreates` GitHub App and invite `@CharlieHelps` as a repository collaborator (Triage role minimum).

---

## Local Tool Installation

Install the tools used by CI locally to catch issues before pushing:

```bash
# macOS
brew install shellcheck shfmt

# Ubuntu/Debian
sudo apt-get install shellcheck
# shfmt: https://github.com/mvdan/sh/releases

# Windows (scoop)
scoop install shellcheck shfmt
```

**Run checks locally:**

```bash
# ShellCheck (static analysis)
shellcheck -x --source-path=scripts/git scripts/git/*.sh

# shfmt (format check)
shfmt -d -i 2 -ci scripts/ hooks/

# shfmt (auto-fix)
shfmt -w -i 2 -ci scripts/ hooks/

# Bats tests
bats tests/unit/
bats tests/integration/
bats tests/unit/ && bats tests/integration/   # full suite

# Or via the parallel runner (recommended locally):
tests/run.sh                                  # fast batch, parallel (skips the slow files)
tests/run.sh --all                            # full suite (fast + slow); what CI runs
tests/run.sh --slow                           # slow batch only
```

Test prerequisites: `bats-core` v1.13.0, `bats-support` v0.3.0, `bats-assert` v2.2.4. A git identity must be configured (`git config user.email` / `user.name`).

The suite is 1148 Bats tests across `tests/unit/` and `tests/integration/`. `tests/run.sh`'s
default run is the **fast batch**: it skips the six heaviest files (`CGW_SLOW_FILES` in
`tests/run.sh`) so local runs stay quick. Use `--all` (or `CGW_RUN_SLOW=1`) for everything, and
`--slow` for the slow batch only. CI always runs the full set (`CI` is set by GitHub Actions).
`CGW_TEST_TIMINGS=1` prints the slowest files (to retune `CGW_SLOW_FILES`) and `CGW_TEST_JOBS=N`
overrides the core count. Naming a file or directory explicitly (e.g.
`tests/run.sh tests/unit/common.bats`) bypasses the gate.
