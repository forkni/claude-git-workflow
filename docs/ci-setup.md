# CI & Code Quality

## GitHub Actions

Three workflows are included in `.github/workflows/`:

| Workflow | Trigger | Checks |
|----------|---------|--------|
| `branch-protection.yml` | Push/PR to `development`, `main` | Local-only file detection, `.gitattributes` presence, ShellCheck (`--severity=error`, over `scripts/git/` and `hooks/`), shfmt format over `scripts/` and `hooks/` (advisory), Bats unit + integration tests |
| `docs-validation.yml` | Push to `development`/`main` or a PR that changes `*.md` files (except `CLAUDE.md`, `MEMORY.md`) | Markdown linting, broken links, spelling of `README.md`, `skill/` and `command/` (all advisory) |
| `release.yml` | Tag push matching `v*` | Creates GitHub Release with auto-generated notes and source archives |

---

## CI Verification Gate

CGW doesn't stop at "push succeeded" — every push it performs (direct push, a merge's
target push, a PR, or a tagged release) is followed by an agent procedure that subscribes
to the resulting GitHub Actions runs, waits for a terminal verdict, and fixes-and-retries
on red rather than reporting the step done. This is an agent-driven procedure (`gh`, not a
`scripts/git/*.sh` wrapper) documented in
[`skill/references/ci-verification.md`](../skill/references/ci-verification.md); it degrades
silently to a no-op when there's no `gh` CLI, no auth, or no GitHub remote.

Knobs (`.cgw.conf` or environment — see [`configuration.md`](configuration.md)):
`CGW_CI_VERIFY` (`0` disables the gate), `CGW_CI_TIMEOUT_SECONDS`, `CGW_CI_POLL_INTERVAL`,
`CGW_CI_MAX_FIX_ROUNDS`, `CGW_CI_REQUIRED_WORKFLOWS`.

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
