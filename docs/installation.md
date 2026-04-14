# Installation

## Quick Start

### Windows (recommended)

```cmd
:: 1. Clone the repo (one-time)
git clone https://github.com/forkni/claude-git-workflow.git

:: 2. Run the installer — prompts for your project path
claude-git-workflow\install.cmd
```

`install.cmd` validates prerequisites, copies scripts into your project, runs `configure.sh` interactively, and offers to clean up temporary files.

### Unix / manual

```bash
# 1. Copy scripts + hook template into your project
cp -r claude-git-workflow/scripts/git/ your-project/scripts/git/
cp -r claude-git-workflow/hooks/ your-project/hooks/
cp -r claude-git-workflow/skill/ your-project/skill/
cp -r claude-git-workflow/command/ your-project/command/

# 2. Auto-configure (scans project, generates config, installs hooks + skill)
cd your-project && ./scripts/git/configure.sh
```

---

## Prerequisites

- **bash 4.0+** — provided by Git for Windows, macOS, or any Linux
- **git 2.0+**
- **Lint tool** (optional) — ruff, eslint, golangci-lint, clang-tidy, cppcheck, or cargo. Set `CGW_LINT_CMD=""` to disable entirely.
- **gh CLI** (optional) — only required for `create_pr.sh` (`gh auth login`)
- **Claude Code CLI** (optional) — only required for Claude Code integration

**Windows:** [Git for Windows](https://git-scm.com/download/win) provides both `bash` and `git`. The installer (`install.cmd`) validates this automatically.

---

## What `configure.sh` Does

`configure.sh` is a one-time setup script. It runs five steps:

1. **Detection** — Scans the project for branch names, lint tools, virtual environments, and files that exist on disk but aren't tracked by git.
2. **Confirmation** — In interactive mode, shows detected values and lets you override each one. Press Enter to accept defaults.
3. **Config generation** — Writes `.cgw.conf` (git-ignored), which tells all CGW scripts about your branches, lint tool, and local-only files.
4. **Hook installation** — Patches the pre-commit and pre-push hook templates with your local-files list and commit prefixes, writes them to `.githooks/`, and copies them into `.git/hooks/`.
5. **Skill installation** — Copies the Claude Code skill and slash command definition into `.claude/` (project-local) or `~/.claude/` (global, with `--global`).

---

## `configure.sh` Options

| Flag | Effect |
|------|--------|
| *(none)* | Interactive: shows detected values, prompts to confirm or override |
| `--non-interactive` | Accept all auto-detected defaults without prompting |
| `--reconfigure` | Overwrite an existing `.cgw.conf` (re-run detection + confirmation) |
| `--skip-hooks` | Skip hook installation |
| `--skip-skill` | Skip Claude Code skill installation |
| `--global` | Install skill to `~/.claude/` (available in every project) instead of `.claude/` |

**Re-running configure.sh:**

```bash
# Update config and hooks after changing lint tool
./scripts/git/configure.sh --reconfigure --skip-skill

# Install skill globally (available in all projects)
./scripts/git/configure.sh --skip-hooks --global

# Fully silent CI/automation install
./scripts/git/configure.sh --non-interactive
```

---

## Troubleshooting

### "bash not found" (Windows)

`install.cmd` prepends `C:\Program Files\Git\bin` to `%PATH%` automatically, but if that path doesn't exist, bash won't be found.

**Fix:** Install [Git for Windows](https://git-scm.com/download/win), then restart your terminal and re-run the installer.

### "Cannot find git repository root"

configure.sh walks up from its location looking for a `.git/` directory and found none.

**Fix:** Make sure you're installing into an initialised git repository. If the target project isn't a repo yet, run `git init` in it first.

### "Hook template not found"

The `hooks/pre-commit` file isn't where configure.sh expects it (relative to `scripts/git/`).

**Fix:** Copy the `hooks/` directory from the CGW source repo into your project root, then re-run configure.sh:
```bash
cp -r /path/to/claude-git-workflow/hooks/ ./hooks/
./scripts/git/configure.sh
```

### "Hooks written to .githooks/ but failed to copy to .git/hooks/"

configure.sh patched and wrote the hooks but `install_hooks.sh` couldn't copy them.

**Fix:** Run the hook installer directly:
```bash
./scripts/git/install_hooks.sh
```
If that also fails, check that `.git/hooks/` is writable by your user.

### "Skill template not found"

The `skill/` or `command/` directory isn't where configure.sh expects it.

**Fix:** Copy both directories from the CGW source repo into your project root:
```bash
cp -r /path/to/claude-git-workflow/skill/ ./skill/
cp -r /path/to/claude-git-workflow/command/ ./command/
./scripts/git/configure.sh
```

### configure.sh exited with a non-zero code (Windows installer)

The installer warns but continues. Check the configure.sh output printed above the warning.

**Fix:** Re-run configure.sh manually from the target project in Git Bash:
```bash
cd "C:\path\to\your-project"
bash scripts/git/configure.sh
```

---

## Uninstalling

To remove CGW from a project:

```bash
# Remove scripts
rm -rf scripts/git/

# Remove hooks
rm -f .git/hooks/pre-commit .git/hooks/pre-push
rm -rf .githooks/

# Remove config
rm -f .cgw.conf cgw.conf.example

# Remove Claude Code integration (if installed locally)
rm -rf .claude/skills/auto-git-workflow/
rm -f .claude/commands/auto-git-workflow.md
```

To remove a globally-installed skill:
```bash
rm -rf ~/.claude/skills/auto-git-workflow/
rm -f ~/.claude/commands/auto-git-workflow.md
```
