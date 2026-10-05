# claude-git-workflow

[![Release](https://img.shields.io/github/v/release/forkni/claude-git-workflow)](https://github.com/forkni/claude-git-workflow/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Branch Protection](https://github.com/forkni/claude-git-workflow/actions/workflows/branch-protection.yml/badge.svg)](https://github.com/forkni/claude-git-workflow/actions/workflows/branch-protection.yml)
[![Documentation Validation](https://github.com/forkni/claude-git-workflow/actions/workflows/docs-validation.yml/badge.svg)](https://github.com/forkni/claude-git-workflow/actions/workflows/docs-validation.yml)

Drop-in git automation and safety toolkit for any software repository. Provides enhanced commits, safe merges, validated pushes, branch sync, and recovery tools — with first-class integrations for **Claude Code** and **Google Antigravity Agents**, backed by a mandatory post-push CI verification gate that follows every push to a green build.

## About

`claude-git-workflow` (CGW) replaces error-prone raw `git` commands with a suite of 30 modular, defensive shell scripts. It bridges human developers and autonomous AI coding agents: developers get reliable safety rails against accidental commits of secrets or local environment files, while AI agents are guided away from destructive git commands via PreToolUse guardrails, conventional commit enforcement, and automated CI test monitoring.

## Features

- **Multi-Tier Safety Gates**: Pre-commit code and Markdown lint validation with interactive auto-fixing, staged-blob congruence checks (failing closed when staged blobs diverge from the validated working tree), and commit subject-length limits (Pro Git 50/72 rule).
- **Blocking Typecheck Verification**: Optional typechecking (`pyrefly`, `pyright`, `mypy`, `tsc`) that is advisory at commit time and strictly blocking prior to push.
- **Safe Merges & Rollbacks**: Automatic pre-merge backup tags, automated resolution of both-deleted (`DD`) conflicts (modify/delete `DU` halts unless opted in), `git rerere` conflict replay, and instantaneous rollback to backup tags (`--revert` history-preserving mode).
- **Post-Push CI Verification Gate**: Watches triggered GitHub Actions or Charlie CI runs until a green verdict is achieved, automatically fixing and retrying test failures up to a configurable round budget.
- **Dual AI Agent Harness Integrations**: Full support for both **Claude Code** and **Google Antigravity Agents**, featuring state-aware repo scanning via `/auto-git-workflow-cmd` and PreToolUse guardrails that intercept and block dangerous raw `git` commands before execution.
- **Repository Health & Recovery**: Linked worktree management (`worktree_manage.sh`), dangling commit discovery (`recover.sh`), automated changelog generation from conventional commits (`changelog_generate.sh`), offline Markdown TOC generation (`md_toc.sh`), and safe branch synchronization across diverged `skip-worktree` files.
- **Cross-Project Batch Maintenance**: Update the CGW script and harness suite across dozens of repositories at once using `cgw-batch-install.cmd` without modifying individual project configs.

## Quick Start (30 seconds)

### Windows (Recommended)

```cmd
:: 1. Clone the repo (one-time)
git clone https://github.com/forkni/claude-git-workflow.git

:: 2. Run the installer — prompts for your project folder and agent preferences
claude-git-workflow\cgw-install.cmd

:: 3. Done — use it (from your project, in Git Bash)
./scripts/git/commit_enhanced.sh "feat: your feature"
```

`cgw-install.cmd` runs pre-install environment checks, prompts whether to configure Claude Code and/or Antigravity Agents, copies scripts into `scripts/git/`, runs `configure.sh` interactively, and offers to clean up temporary staging files.

Already maintain CGW in multiple repositories? `cgw-batch-install.cmd` refreshes the toolkit across all configured target projects in one step without touching any project's `.cgw.conf` — see [Installation](docs/installation.md#batch-updating-multiple-projects-windows).

### Unix / Manual Setup

```bash
# 1. Clone the repository
git clone https://github.com/forkni/claude-git-workflow.git

# 2. Copy scripts into your project
mkdir -p your-project/scripts/git
cp -r claude-git-workflow/scripts/git/* your-project/scripts/git/

# 3. Auto-configure (scans project, generates .cgw.conf, installs hooks and agent skills)
cd your-project && ./scripts/git/configure.sh --template-dir ../claude-git-workflow

# 4. Done — use it
./scripts/git/commit_enhanced.sh "feat: your feature"
```

> [!NOTE]
> `configure.sh` auto-detects your branch conventions, linters, typecheckers, and local-only files. If preferred, you can also copy staging directories (`hooks/`, `skill/`, `command/`, `templates/`) into your project root prior to running `./scripts/git/configure.sh`.

## Usage Examples

### Daily Git Operations

```bash
# Enhanced commit: validates lint/format, checks congruence, verifies 50/72 subject format
./scripts/git/commit_enhanced.sh "feat(auth): implement token refresh"

# Stage only specific files or specific paths
./scripts/git/commit_enhanced.sh --only src/auth.py "fix: handle expired tokens"

# Sync local branches with remote (safely protects skip-worktree local files)
./scripts/git/sync_branches.sh

# Safe source-to-target merge (creates backup tag, auto-resolves clean conflicts)
./scripts/git/merge_with_validation.sh

# Push with remote reachability check, blocking typecheck, and CI verification gate
./scripts/git/push_validated.sh

# Inspect changes vs default branch before merging
./scripts/git/branch_diff.sh --stat

# Undo last commit while keeping changes staged
./scripts/git/undo_last.sh

# Reflog browsing and dangling-commit recovery
./scripts/git/recover.sh
```

### AI Agent Interface (`/auto-git-workflow-cmd`)

When working in Claude Code or Antigravity, type `/auto-git-workflow-cmd` to open the state-aware interactive menu:

1. **⭐ Full promotion**: The entire pipeline in one action — validates pre-commit rules, commits staged changes, pushes the feature branch, merges to target (or opens a PR), pushes target, and watches CI runs to completion.
2. **Commit & Stash**: Commit staged files, stash work safely with untracked files, auto-fix lint violations.
3. **Push, Pull & Sync**: Validate remote reachability, run blocking typechecks, sync branches, and trigger the CI gate.
4. **Branch, Merge & PR**: Validate branch state, preview diffs with `branch_diff.sh`, merge safely, or create GitHub PRs.
5. **Undo & Recover**: Undo commits, browse reflog history, recover lost dangling commits via `recover.sh`.
6. **Release & Maintain**: Tag releases (`create_release.sh`), generate changelogs (`changelog_generate.sh`), manage linked worktrees (`worktree_manage.sh`), and inspect repo health (`repo_health.sh`).

The command scans repository status before rendering the menu and pre-selects the logical next step (e.g., suggesting a commit if dirty files exist, or a push if the branch is ahead).

## AI Agent Harness Integrations

CGW integrates natively with two major AI agent environments:

### 1. Claude Code

- **Skill**: Installed to `.claude/skills/auto-git-workflow/` (or global `~/.claude/skills/auto-git-workflow/`). Teaches Claude to invoke `scripts/git/*.sh` wrappers instead of bare git commands.
- **Slash Command**: `/auto-git-workflow-cmd` menu definition installed in `.claude/commands/`.
- **PreToolUse Guardrail**: `hooks/cc-block-dangerous-git.sh` configured in `.claude/settings.json`, intercepting Bash tool executions to prevent raw destructive git invocations.

### 2. Google Antigravity Agents

- **Skill**: Installed to `.agents/skills/auto-git-workflow/` (or global `~/.gemini/config/skills/auto-git-workflow/`).
- **Slash Command**: Packaged as `.agents/skills/auto-git-workflow-cmd/SKILL.md` for native invocation.
- **PreToolUse Guardrail**: `hooks/agy-block-dangerous-git.cmd` (Windows) and `hooks/agy-block-dangerous-git.sh` (Unix) registered in `.agents/hooks.json` (or `~/.gemini/config/hooks.json`), intercepting `run_command` tool calls before execution.

See [Claude Code Integration](docs/claude-code-integration.md) for detailed configuration and global installation instructions.

## What's Included

CGW provides 30 user-facing scripts and 2 internal core modules in `scripts/git/`:

| Script | Purpose |
|--------|---------|
| `configure.sh` | One-time setup — scans project, generates `.cgw.conf`, installs hooks, and configures agent skills/guardrails |
| `commit_enhanced.sh` | Working-tree lint/format validation, staged-blob congruence check, local-only file protection, Pro Git 50/72 commit check (`--only`, `--all`, `--staged-only`, `--sign`) |
| `merge_with_validation.sh` | Safe source→target merge: creates backup tag, auto-resolves DD conflicts, stops on DU/UU, supports `diff3`/`zdiff3` conflict style and `rerere` (`--source`, `--target`, `--dry-run`) |
| `rollback_merge.sh` | Emergency rollback to pre-merge backup tag (`--revert` for safe history-preserving rollback) |
| `cherry_pick_commits.sh` | Cherry-pick with source branch validation, dev-only file warnings, and backup tag (`--only <pathspec>` for partial picks) |
| `merge_docs.sh` | Documentation-only merge from source branch to target branch |
| `push_validated.sh` | Push with remote reachability check, blocking typecheck validation (`--pushed-only` checks the committed branch, ignoring uncommitted work), force-push lease guards, and CI verification gate trigger |
| `sync_branches.sh` | Sync local branches via fetch + rebase (protected branches use `--ff-only` and refuse when diverged); auto-protects diverged `skip-worktree` local files across pulls |
| `validate_branches.sh` | Check repository and branch state before critical operations (uncommitted changes, ahead/behind counts, tracking refs) |
| `branch_diff.sh` | Show diff against the target branch (`--files`, `--stat`, `--no-ws`, `--base`) |
| `check_lint.sh` | Read-only lint, format, typecheck, and Markdown validation (`--modified-only`, `--skip-md-lint`, `--skip-typecheck`, `--ref`/`--base`/`--unpushed` to check the committed snapshot) |
| `fix_lint.sh` | Auto-fix code lint, code formatting, and Markdown issues (`--modified-only`, `--md-only`, `--skip-md-lint`) |
| `create_pr.sh` | Create GitHub PR from source to target branch via `gh` CLI (triggers Charlie CI and GitHub Actions) |
| `merge_pr.sh` | Guarded, logged wrapper around `gh pr merge --merge` with an explicit `--repo`; refuses non-OPEN PRs and non-green PR checks (`--wait-checks`, `--skip-checks`), `--retarget <M>` for stacked PRs, `--squash`/`--rebase` need `--allow-non-merge` (`--delete-branch`, `--dry-run`) |
| `pr_checkout.sh` | Guarded, logged wrapper around `gh pr checkout <N>` for reviewing PRs locally (`--branch`, `--force`, `--detach`, `--dry-run`) |
| `install_hooks.sh` | Install git hooks (`pre-commit`, `pre-push`, `pre-rebase`) into `.githooks/` and `.git/hooks/` |
| `setup_attributes.sh` | Generate `.gitattributes` for binary, text, and asset handling (Python, TouchDesigner, GLSL, LF line endings) |
| `clean_build.sh` | Safe cleanup of build artifacts with dry-run default (`--dry-run`, `--force`) |
| `create_release.sh` | Create annotated version tags to trigger GitHub Release workflows (`--sign` for GPG/SSH tags, `--allow-non-semver` for archive tags) |
| `stash_work.sh` | Safe stash wrapper with untracked file support, named stashes, non-interactive drop/clear, and logging |
| `repo_health.sh` | Repository health inspection: integrity verification (`git fsck`), repository size report, large file discovery, git gc |
| `bisect_helper.sh` | Guided git bisect with backup tag, automated good-ref detection, and test script runner |
| `rebase_safe.sh` | Safe rebase: automatic backup tag, published-commit guards, abort/continue/skip commands, autostash |
| `branch_cleanup.sh` | Prune merged branches, stale remote-tracking refs, and obsolete backup tags (`--dry-run`, `--force`) |
| `changelog_generate.sh` | Generate categorized Markdown/text changelog from conventional commits (`--version`, `--prepend` for cumulative `CHANGELOG.md`) |
| `md_toc.sh` | Offline Markdown table-of-contents generator/inserter with GitHub-compatible anchor slugs (`--insert`, `--check`, `--all`) |
| `undo_last.sh` | Undo last commit (keeps changes staged), unstage files, discard changes, or amend commit message |
| `recover.sh` | Reflog exploration, dangling-commit discovery (`git fsck`), and safe branch restoration from any SHA |
| `worktree_manage.sh` | Linked worktree management: list, add, link CGW tooling into worktrees, remove (dry-run default), prune stale metadata |
| `check_local_files.sh` | Verify no local-only files (`CLAUDE.md`, `MEMORY.md`, `.env`, logs) are tracked in git (used by CI branch protection) |

**Internal Core Modules**:

- `_common.sh`: Shared utilities, logging, platform shims, backup-tag registry, interactive confirmation prompts (`cgw_confirm`), sourced by every script.
- `_config.sh`: Three-tier configuration loader, repository root auto-detection, and centralized settings registry.

## Configuration

CGW uses a three-tier configuration hierarchy:

```text
Priority 1: Environment variables (CGW_*)   ← CI/automation overrides (always wins)
Priority 2: .cgw.conf                        ← Project configuration generated by configure.sh
Priority 3: Built-in defaults                ← Safe defaults; works without any configuration file
```

### Key Settings Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `CGW_SOURCE_BRANCH` | *(none)* | Branch where development occurs (`development`, `develop`, `dev`, etc.). Set by `configure.sh` when detected, or passed via `--source` |
| `CGW_TARGET_BRANCH` | *(auto-detected)* | Stable production branch (auto-detected at runtime from `origin/HEAD` → `main` → `master` → `main`) |
| `CGW_REMOTE` | `origin` | Remote name for fetch and push (use `upstream` for forks) |
| `CGW_LOCAL_FILES` | `CLAUDE.md MEMORY.md .claude/ logs/` | Files and directories never committed to git (auto-unstaged by `commit_enhanced.sh`) |
| `CGW_LOCAL_FILES_EXEMPT` | `""` | Exact paths exempted from local-only file protection (e.g. `.claude/settings.json`) |
| `CGW_LINT_CMD` | `ruff` | Primary lint tool (`""` to disable) |
| `CGW_FORMAT_CMD` | `ruff` | Code formatter (`""` to disable) |
| `CGW_TYPECHECK_CMD` | `""` | Typecheck tool (`pyrefly`, `pyright`, `mypy`, `tsc`). Advisory at commit time, **blocking** at push |
| `CGW_MARKDOWNLINT_CMD` | *(auto-detected)* | Markdown linter (`markdownlint-cli2` → `markdownlint` → `npx` fallback → disabled) |
| `CGW_ALLOW_STAGED_DIVERGENCE` | `0` | `0` = fail commit closed if staged blob differs from validated working tree; `1` = allow staged-only divergence |
| `CGW_COMMIT_SUBJECT_SOFT_LEN` | `50` | Soft subject line length limit (displays advisory guidance if exceeded) |
| `CGW_COMMIT_SUBJECT_HARD_LEN` | `72` | Hard subject line length limit (blocks commit when `CGW_ENFORCE_SUBJECT_LENGTH=1`) |
| `CGW_FREEFORM_MESSAGE_BRANCHES` | `""` | Space-separated branch globs exempt from commit format checks (e.g. `up/*` for upstream PRs) |
| `CGW_MERGE_MODE` | `direct` | Promotion strategy: `direct` (merge locally via `merge_with_validation.sh`) or `pr` (create PR via `create_pr.sh`) |
| `CGW_SIGN_COMMITS` | `0` | `1` to sign commits with GPG/SSH (`git commit -S`) |
| `CGW_SIGN_TAGS` | `0` | `1` to sign release tags (`git tag -s`) |
| `CGW_ALLOW_REBASE_PUBLISHED` | `0` | `0` = abort rebase if commits were already pushed to remote; `1` = allow rebasing published commits |
| `CGW_CI_VERIFY` | `1` | `1` = agent CI verification gate watches post-push runs until green; `0` = disable gate |
| `CGW_AUTO_REMOVE_INDEX_LOCK` | `1` | Automatically detect and remove abandoned `.git/index.lock` files left by crashed processes |

See [Configuration Guide](docs/configuration.md) for full options and ecosystem examples (Python, JavaScript/TypeScript, Go, Rust, C/C++), or inspect [`cgw.conf.example`](cgw.conf.example).

## Documentation

| Document | Purpose |
|----------|---------|
| [Installation Guide](docs/installation.md) | Setup steps, `configure.sh` flags, troubleshooting, and batch multi-project updates |
| [Usage Guide](docs/usage.md) | Command-line examples for every script, conventional commit formats, and flag references |
| [Configuration Reference](docs/configuration.md) | Three-tier configuration system details, options registry, and multi-language lint recipes |
| [CI Setup & Verification](docs/ci-setup.md) | GitHub Actions workflows, Charlie CI integration, local tool installation, and the CI gate |
| [Agent Integrations](docs/claude-code-integration.md) | Claude Code and Antigravity Agents skills, `/auto-git-workflow-cmd` menu, and guardrail setup |
| [Known Issues](docs/KNOWN_ISSUES.md) | Documented platform behaviors, workarounds, and resolved edge cases |
| [Configuration Example](cgw.conf.example) | Fully documented reference `.cgw.conf` file with examples for all settings |
| [Changelog](CHANGELOG.md) | Comprehensive release history and detailed version notes |

## Requirements & Compatibility

- **Shell & Git**: `bash` 4.0+ and `git` 2.0+ (Linux, macOS, WSL, or Git for Windows).
- **Linters & Formatters** (optional): `ruff`, `eslint`, `prettier`, `golangci-lint`, `clang-tidy`, `cppcheck`, or `cargo` (disable with `CGW_LINT_CMD=""`).
- **Markdown Linting** (optional): `markdownlint-cli2`, `markdownlint`, or `npx` (requires Node.js >= 20 supporting RegExp `v` flag).
- **Typecheckers** (optional): `pyrefly`, `pyright`, `mypy`, `tsc` (disable with `CGW_TYPECHECK_CMD=""`).
- **AI Agent Harnesses** (optional): [Claude Code CLI](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview) or [Google Antigravity](https://github.com/google/antigravity).
- **GitHub CLI** (optional): `gh` CLI authenticated (`gh auth login`) for PR creation (`create_pr.sh`) and the CI verification gate.
- **Utility Tools** (optional): `jq` for JSON merging in `configure.sh` (automatic Python fallback runs if `jq` is absent). On Windows: `winget install jqlang.jq`.

## Contributing

Contributions, bug reports, and suggestions are welcome!

### Development & Testing

- Ensure prerequisites are installed: `bash 4.0+`, `git`, `bats-core` (v1.13.0), `bats-support`, `bats-assert`, `shellcheck`, and `shfmt`.
- Run the test suite:

```bash
# Run unit and integration tests in parallel
tests/run.sh

# Run including slower test suites
CGW_RUN_SLOW=1 tests/run.sh
```

- Run static analysis and formatting checks:

```bash
# ShellCheck static analysis
shellcheck -x --source-path=scripts/git scripts/git/*.sh

# shfmt format check
shfmt -d -i 2 -ci scripts/
```

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for contributor guidelines and project credits.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
