# claude-git-workflow

[![Release](https://img.shields.io/github/v/release/forkni/claude-git-workflow)](https://github.com/forkni/claude-git-workflow/releases)

Drop-in git automation for any project. Enhanced commits, safe merges, validated pushes, branch sync — with optional Claude Code integration, including a mandatory CI verification gate that watches every push through to a green GitHub Actions run (or fixes it until it is one).

## Quick Start (30 seconds)

### Windows (recommended)

```cmd
:: 1. Clone the repo (one-time)
git clone https://github.com/forkni/claude-git-workflow.git

:: 2. Run the installer — prompts for your project path
claude-git-workflow\cgw-install.cmd

:: 3. Done — use it (from your project, in Git Bash)
./scripts/git/commit_enhanced.sh "feat: your feature"
```

`cgw-install.cmd` runs pre-install checks, copies scripts, runs `configure.sh` interactively, and cleans up temporary files.

Already have CGW installed in several projects? `cgw-batch-install.cmd` refreshes the toolkit across all of them in one run, without touching any project's `.cgw.conf` — see [Installation](docs/installation.md).

### Unix / manual

```bash
# 1. Copy scripts and staging directories into your project
cp -r claude-git-workflow/scripts/git/ your-project/scripts/git/
cp -r claude-git-workflow/hooks/ your-project/hooks/
cp -r claude-git-workflow/skill/ your-project/skill/
cp -r claude-git-workflow/command/ your-project/command/

# 2. Auto-configure (scans project, generates config, installs hooks + skill)
#    configure.sh installs hooks to .githooks/ + .git/hooks/ and copies
#    the skill/command into .claude/ — then you can remove hooks/, skill/, command/
cd your-project && ./scripts/git/configure.sh

# 3. Done — use it
./scripts/git/commit_enhanced.sh "feat: your feature"
```

No manual config editing required for common setups. `configure.sh` auto-detects your branch names, lint tool, and local-only files.

---

## What's Included

| Script | Purpose |
|--------|---------|
| `configure.sh` | One-time setup — scans project, generates `.cgw.conf`, installs hooks |
| `commit_enhanced.sh` | Lint validation + local-only file protection + commit message format check; `--sign` for GPG/SSH-signed commits |
| `merge_with_validation.sh` | Safe merge source→target: backup tag, auto-resolve DU/DD conflicts, stop on UU. `--source`/`--target` override the configured branch pair per-invocation. |
| `rollback_merge.sh` | Emergency rollback to pre-merge backup tag; `--revert` for safe history-preserving mode |
| `cherry_pick_commits.sh` | Cherry-pick with source branch validation and backup tag; `--only <pathspec>` (repeatable) for partial picks |
| `merge_docs.sh` | Documentation-only merge from source to target |
| `push_validated.sh` | Push with remote reachability check + force-push protection |
| `sync_branches.sh` | Sync local branches via fetch + rebase; auto-protects diverged `skip-worktree` local files across the pull |
| `validate_branches.sh` | Check branch state before operations |
| `branch_diff.sh` | Show what changed on the current branch vs. the default branch; `--files`/`--stat`/`--no-ws`/`--base` refine the diff |
| `check_lint.sh` | Read-only lint validation (code + Markdown) |
| `fix_lint.sh` | Auto-fix lint issues (code + Markdown; `--skip-md-lint`/`--md-only`/`--modified-only`) |
| `create_pr.sh` | Create GitHub PR from source → target (triggers Charlie CI + GitHub Actions) |
| `pr_checkout.sh` | Guarded, logged wrapper around `gh pr checkout <N>` for reviewing PRs locally; `--branch`/`--force`/`--detach`/`--dry-run` supported |
| `install_hooks.sh` | Install git hooks (pre-commit, pre-push, pre-rebase) |
| `setup_attributes.sh` | Generate `.gitattributes` for binary and text files (Python, TouchDesigner, GLSL, assets) |
| `clean_build.sh` | Safe cleanup of build artifacts with dry-run default (Python, TouchDesigner, GLSL) |
| `create_release.sh` | Create annotated version tags to trigger the GitHub Release workflow; `--sign` for GPG/SSH-signed tags |
| `stash_work.sh` | Safe stash wrapper with untracked file support, named stashes, non-interactive drop/clear, and logging |
| `repo_health.sh` | Repository health: integrity check, size report, large file detection, gc |
| `bisect_helper.sh` | Guided git bisect with backup tag, auto-detect good ref, automated test support |
| `rebase_safe.sh` | Safe rebase: backup tag, pushed-commit guard, abort/continue/skip, autostash |
| `branch_cleanup.sh` | Prune merged branches, stale remote-tracking refs, and old backup tags |
| `changelog_generate.sh` | Generate categorized markdown/text changelog from conventional commits; `--version`/`--prepend` build a cumulative `CHANGELOG.md` across releases |
| `md_toc.sh` | Offline Markdown table-of-contents generator/inserter with GitHub-compatible heading slugs; `--insert`/`--check`/`--all` |
| `undo_last.sh` | Undo last commit (keep staged), unstage files, discard changes, amend message |
| `recover.sh` | Reflog browsing, dangling-commit discovery (`git fsck`), and safe branch restore from any SHA |
| `worktree_manage.sh` | Linked worktree management: list, add, remove (with dry-run default), prune stale admin files |
| `check_local_files.sh` | Verify no local-only files are tracked in git (used by CI branch-protection workflow) |

Internal modules (not user-facing): `_common.sh` (shared utilities, sourced by every script), `_config.sh` (three-tier config resolution, sourced by `_common.sh`).

---

## Configuration

Scripts use a three-tier resolution system — environment variables override `.cgw.conf`, which overrides built-in defaults. Works out of the box without any config.

| Variable | Default | Description |
|----------|---------|-------------|
| `CGW_SOURCE_BRANCH` | `development` | Branch where development happens |
| `CGW_TARGET_BRANCH` | `main` | Stable/production branch |
| `CGW_REMOTE` | `origin` | Remote name for fetch/push (use `upstream` for forks) |
| `CGW_LOCAL_FILES` | `CLAUDE.md MEMORY.md .claude/ logs/` | Files never committed |
| `CGW_LOCAL_FILES_EXEMPT` | `""` | Files exempted from local-only protection (exact paths) |
| `CGW_LINT_CMD` | `ruff` | Lint tool (`""` to disable) |
| `CGW_MERGE_MODE` | `direct` | `direct` (local merge) or `pr` (create GitHub PR) |
| `CGW_SIGN_COMMITS` | `0` | `1` to GPG/SSH-sign commits (passes `-S` to `git commit`; respects `gpg.format`) |
| `CGW_SIGN_TAGS` | `0` | `1` to GPG/SSH-sign release tags (passes `-s` to `git tag`) |
| `CGW_ALLOW_REBASE_PUBLISHED` | `0` | `1` to allow rebasing commits already pushed to remote (pre-rebase hook will otherwise abort) |

See [docs/configuration.md](docs/configuration.md) for all options and language-specific lint examples (Python, JS, Go, Rust, C++).

---

## Documentation

| Guide | Contents |
|-------|----------|
| [Installation](docs/installation.md) | Detailed install steps, configure.sh options, troubleshooting |
| [Usage](docs/usage.md) | All script examples, commit format, branch setup, env vars |
| [Configuration](docs/configuration.md) | Config system, all options, lint examples for 7 ecosystems |
| [CI Setup](docs/ci-setup.md) | GitHub Actions, Charlie CI, local tool install |
| [Claude Code](docs/claude-code-integration.md) | Skill (`auto-git-workflow`) + `/auto-git-workflow-cmd` state-aware git menu — install (local and global) |
| [Shell Style Audit](docs/STYLE_AUDIT.md) | Google Shell Style Guide compliance report and fixes (v0.3.0) |
| [cgw.conf.example](cgw.conf.example) | Inline-documented reference for every config variable |

---

## Requirements

- bash 4.0+
- git 2.0+
- For lint: ruff / flake8 / eslint / golangci-lint / clang-tidy / cppcheck / cargo (or none — set `CGW_LINT_CMD=""`)
- For Claude Code integration: Claude Code CLI
- For PR creation (`create_pr.sh`): [gh CLI](https://cli.github.com/) + `gh auth login`
- `jq` (optional): used by `configure.sh` to install the Claude Code guardrail into `.claude/settings.json`; a Python fallback runs automatically if absent. Install on Windows: `winget install jqlang.jq`

Compatible with: Linux, macOS, Windows (Git Bash / WSL)

**Windows installer** (`cgw-install.cmd`) requires only [Git for Windows](https://git-scm.com/download/win) — it validates bash availability as part of its pre-install checks.

---

## License

MIT — see [LICENSE](LICENSE)
