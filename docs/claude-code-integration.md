# AI Agent Harness Integrations (Claude Code & Antigravity)

## Overview

`claude-git-workflow` (CGW) provides drop-in integrations for two major AI agent environments: **Claude Code** and **Google Antigravity Agents**.

These integrations provide two defensive layers:

1. **Skills & Slash Command**: Teaches the agent to use `scripts/git/*.sh` wrapper scripts instead of raw `git` commands, ensuring lint checks, local-file protection, backup tags, and CI verification are never bypassed. Includes the interactive `/auto-git-workflow-cmd` menu.
2. **PreToolUse Guardrails**: Hard enforcement at the harness layer. Intercepts tool calls before execution and blocks dangerous raw git commands (e.g., bare `git commit`, `git push`, `git merge`, `git reset --hard`, `git checkout -b`), printing an explanatory message that directs the agent to the corresponding CGW wrapper script.

---

## Harness Comparison

| Feature | Claude Code | Google Antigravity Agents |
|---|---|---|
| **Skill Location (Local)** | `.claude/skills/auto-git-workflow/` | `.agents/skills/auto-git-workflow/` |
| **Skill Location (Global)** | `~/.claude/skills/auto-git-workflow/` | `~/.gemini/config/skills/auto-git-workflow/` |
| **Command Location (Local)** | `.claude/commands/auto-git-workflow-cmd.md` | `.agents/skills/auto-git-workflow-cmd/SKILL.md` |
| **Command Location (Global)** | `~/.claude/commands/auto-git-workflow-cmd.md` | `~/.gemini/config/skills/auto-git-workflow-cmd/SKILL.md` |
| **Guardrail Script** | `hooks/cc-block-dangerous-git.sh` | `hooks/agy-block-dangerous-git.cmd` (Win) / `.sh` (Unix) |
| **Guardrail Config** | `.claude/settings.json` | `.agents/hooks.json` (or `~/.gemini/config/hooks.json`) |
| **Target Tool Intercepted** | Bash tool invocations | `run_command` tool calls |

---

## Automatic Installation

### Windows (`cgw-install.cmd`)

The interactive Windows installer prompts you to configure Claude Code, Antigravity Agents, or both:

```cmd
claude-git-workflow\cgw-install.cmd
```

It validates prerequisites, copies scripts and staging files, installs hooks, registers skills, and configures the guardrails in `.claude/settings.json` and `.agents/hooks.json`.

### Unix / Manual (`configure.sh`)

`configure.sh` automatically detects present directories (`.claude/` or `.agents/`) and offers to install the corresponding harness files:

```bash
# Interactive setup (prompts for each harness)
./scripts/git/configure.sh

# Or install with explicit flags:
./scripts/git/configure.sh --claude --antigravity
```

### Installation Flags for `configure.sh`

| Flag | Purpose |
|---|---|
| `--claude` | Explicitly enable Claude Code integration |
| `--antigravity` | Explicitly enable Antigravity Agents integration |
| `--skip-claude` | Skip Claude Code skill, slash command, and guardrail |
| `--skip-antigravity` | Skip Antigravity skill, command, and guardrail |
| `--skip-cc-guardrail` | Install Claude Code skill/command but skip its PreToolUse guardrail |
| `--skip-agy-skill` | Skip Antigravity skill/command installation |
| `--skip-agy-guardrail` | Skip Antigravity PreToolUse guardrail |
| `--global` | Install skills and guardrails globally (`~/.claude/` and `~/.gemini/config/`) |

---

## Global vs Local Installation

- **Local (default)**: Installed directly into the project's `.claude/` and `.agents/` directories. Active only within that repository. Both directories are git-ignored by default.
- **Global (`--global`)**: Installed into `~/.claude/` and `~/.gemini/config/`. Makes CGW skills and guardrails available across **every project** on your machine:

```bash
# Global install
./scripts/git/configure.sh --global
```

---

## The `/auto-git-workflow-cmd` Slash Command

Both harnesses support the `/auto-git-workflow-cmd` slash command. It opens a state-aware interactive menu:

1. **⭐ Full promotion**: The entire release pipeline in one command — runs pre-commit validation, commits staged changes, pushes the feature branch, merges to target (or opens a PR), pushes target, and monitors CI runs to completion.
2. **Commit & Stash**: Commit staged files, stash work safely with untracked files, auto-fix lint violations.
3. **Push, Pull & Sync**: Validate remote reachability, run blocking typechecks, sync branches, and trigger the CI gate.
4. **Branch, Merge & PR**: Validate branch state, preview diffs with `branch_diff.sh`, merge safely, or create GitHub PRs.
5. **Undo & Recover**: Undo commits, browse reflog history, recover lost dangling commits via `recover.sh`.
6. **Release & Maintain**: Tag releases (`create_release.sh`), generate changelogs (`changelog_generate.sh`), manage linked worktrees (`worktree_manage.sh`), and inspect repo health (`repo_health.sh`).

### State-Aware Scanning

Before displaying the menu, `/auto-git-workflow-cmd` inspects repository status (uncommitted work, ahead/behind counts, in-progress rebase/merge, stash stack) and pre-selects the likely next action.

### Post-Push CI Verification Gate

Every push performed through `/auto-git-workflow-cmd` (or via `push_validated.sh` in agent workflows) is followed by the **CI Verification Gate**:

- The agent subscribes to GitHub Actions / Charlie CI runs triggered by the push.
- Watches until all runs reach a terminal state.
- If a workflow fails, the agent inspects the failure logs, attempts a fix, re-commits, re-pushes, and re-watches (up to `CGW_CI_MAX_FIX_ROUNDS=3`).
- See [CI Setup](ci-setup.md#ci-verification-gate) for details.

---

## PreToolUse Guardrails

Guardrails run before the agent executes a shell command:

- **Claude Code**: Registered as a `PreToolUse` hook in `.claude/settings.json`. Intercepts Bash tool calls matching patterns like `git commit`, `git push`, `git merge`, `git checkout -b`, `git reset --hard`, and `git branch -D`.
- **Antigravity Agents**: Registered in `.agents/hooks.json` (or `~/.gemini/config/hooks.json`) as a `pre_tool_use` hook on the `run_command` tool. Uses `agy-block-dangerous-git.cmd` on Windows and `agy-block-dangerous-git.sh` on Unix.

When an agent attempts a blocked command, the guardrail rejects execution with an exit code of `2` and surfaces guidance:

```text
[BLOCKED] Dangerous raw git command intercepted: git commit -m "..."
Use CGW enhanced script instead:
  ./scripts/git/commit_enhanced.sh "..."
```

---

## Verifying Integrations

### In Claude Code

1. Type `/skills` and confirm `auto-git-workflow` appears in the list.
2. If missing, verify `.claude/skills/auto-git-workflow/SKILL.md` exists and restart Claude Code.

### In Google Antigravity

1. In the agent CLI, check `.agents/skills.json` or `.agents/skills/` to confirm `auto-git-workflow` and `auto-git-workflow-cmd` are present.
2. Check `.agents/hooks.json` to verify the `agy-block-dangerous-git` hook entry exists.
