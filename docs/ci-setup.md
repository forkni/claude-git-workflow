# CI & Code Quality

## GitHub Actions

Three workflows are included in `.github/workflows/`:

| Workflow | Trigger | Checks |
|----------|---------|--------|
| `branch-protection.yml` | Push/PR to `development`, `main` | Local-only file detection, `.gitattributes` presence, ShellCheck, shfmt format (advisory), Bats unit + integration tests |
| `docs-validation.yml` | Changes to `*.md` files | Markdown linting, broken links, spelling (all advisory) |
| `release.yml` | Tag push matching `v*` | Creates GitHub Release with auto-generated notes and source archives |

---

## Charlie CI Agent

This project uses [Charlie](https://charlielabs.ai) for AI-assisted code review on pull requests.

```yaml
# .charlie/config.yml
checkCommands:
  fix: shfmt -w -i 2 -ci scripts/   # auto-format after edits
  lint: shellcheck -x --source-path=scripts/git scripts/git/*.sh  # static analysis
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
shfmt -d -i 2 -ci scripts/

# shfmt (auto-fix)
shfmt -w -i 2 -ci scripts/

# Bats tests
bats tests/unit/
bats tests/integration/
bats tests/unit/ && bats tests/integration/   # full suite
```

Test prerequisites: `bats-core` v1.13.0, `bats-support` v0.3.0, `bats-assert` v2.2.4. A git identity must be configured (`git config user.email` / `user.name`).
