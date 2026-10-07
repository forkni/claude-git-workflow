# AI Agent Harness Integrations (Claude Code & Antigravity)

## Overview

`claude-git-workflow` (CGW) provides drop-in integrations for two major AI agent environments: **Claude Code** and **Google Antigravity Agents**.

These integrations provide two defensive layers:

1. **Skills & Slash Command**: Teaches the agent to use `scripts/git/*.sh` wrapper scripts instead of raw `git` commands, ensuring lint checks, local-file protection, backup tags, and CI verification are never bypassed. Includes the interactive `/auto-git-workflow-cmd` menu.
2. **PreToolUse Guardrails**: Hard enforcement at the harness layer. Intercepts tool calls before execution and blocks dangerous raw git commands (e.g., bare `git commit`, `--no-verify`, force-push, `git reset --hard`, `git branch -D`, `git checkout .`, raw `git worktree remove`), printing an explanatory message that directs the agent to the corresponding CGW wrapper script.

---

## Harness Comparison

| Feature | Claude Code | Google Antigravity Agents |
|---|---|---|
| **Skill Location (Local)** | `.claude/skills/auto-git-workflow/` | `.agents/skills/auto-git-workflow/` |
| **Skill Location (Global)** | `~/.claude/skills/auto-git-workflow/` | `~/.gemini/config/skills/auto-git-workflow/` |
| **Command Location (Local)** | `.claude/commands/auto-git-workflow-cmd.md` | `.agents/skills/auto-git-workflow-cmd/SKILL.md` |
| **Command Location (Global)** | `~/.claude/commands/auto-git-workflow-cmd.md` | `~/.gemini/config/skills/auto-git-workflow-cmd/SKILL.md` |
| **Guardrail Script** | `.claude/hooks/cc-block-dangerous-git.sh` (+ `_guardrail_core.sh`) | `.agents/hooks/agy-block-dangerous-git.cmd` (Win) / `.sh` (Unix) (+ `_guardrail_core.sh`) |
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

- **Local (default)**: Installed directly into the project's `.claude/` and `.agents/` directories. Active only within that repository. Neither directory is added to `.gitignore` automatically (only `logs/`, `.cgw.conf` and `.cgw.conf.bak` are), so add them yourself if you don't want to commit them.
- **Global (`--global`)**: Installed into `~/.claude/` and `~/.gemini/config/`. Makes CGW skills and guardrails available across **every project** on your machine:

```bash
# Global install
./scripts/git/configure.sh --global
```

---

## The `/auto-git-workflow-cmd` Slash Command

Both harnesses support the `/auto-git-workflow-cmd` slash command. It opens a state-aware interactive menu:

1. **⭐ Full promotion**: commit → push → merge/PR → push, the full pipeline in one run.
2. **Commit & Stash**: commit, amend the message, stash and restore work in progress.
3. **Push, Pull & Sync**: push, publish a branch, sync branches with the remote.
4. **Branch, Merge & PR**: merge, rebase, create or check out a PR, cherry-pick.
5. **Undo & Recover**: undo a commit, unstage/discard, roll back a merge, rescue commits from the reflog.
6. **Release & Maintain**: tag a release, generate a changelog, check repo health, clean artifacts.

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

- **Claude Code**: Registered as a `PreToolUse` hook in `.claude/settings.json`. Intercepts Bash tool calls matching patterns like `git commit`, `--no-verify`, `git push --force` (`--force-with-lease` is allowed), `git reset --hard`, `git branch -D`, and `git checkout .`. Other raw commands such as plain `git push` or `git merge` are not intercepted; the skill rules direct the agent to the wrapper scripts, and the git hooks remain the enforcement layer.
- **Antigravity Agents**: Registered in `.agents/hooks.json` (or `~/.gemini/config/hooks.json`) under the `cgw-git-guardrail` → `PreToolUse` key, matching the `run_command` tool. Uses `agy-block-dangerous-git.cmd` on Windows and `agy-block-dangerous-git.sh` on Unix.

**git-guardrail mod supersedes the Claude Code shell hook.** On a machine where the in-process `git-guardrail` mod is deployed (`~/.claude/mods/git-guardrail`) and wired up (`CLAUDE_CODE_PLUGIN_DIRS` in the environment or in `~/.claude/settings.json` names it), `configure.sh` — and therefore `cgw-install.cmd` and `cgw-batch-install.cmd` — no longer installs `cc-block-dangerous-git.sh`. It also retires an existing install: the `PreToolUse` entry is removed (other hooks such as `ExitPlanMode` are kept), and `.claude/hooks/cc-block-dangerous-git.sh` and `_guardrail_core.sh` are deleted when they match the stock copies; customised copies are kept with a warning. Machines without the mod keep the shell hook, so re-running the batch updater on another machine needs no extra steps. The Antigravity guardrail is separate (own adapter and core copy under `.agents/hooks/`) and is never touched.

When an agent attempts a blocked command, the guardrail rejects it and surfaces guidance. The Claude Code hook exits with code `2` and prints the message to stderr; the Antigravity hook returns `{"decision": "deny", "reason": ...}` and exits `0`:

```text
BLOCKED: Command matched dangerous pattern "git commit".
Use ./scripts/git/commit_enhanced.sh "<type>: <msg>" instead — it runs lint, protects local-only files, and enforces conventional commit format.
The user has prevented you from doing this.
```

---

## Verifying Integrations

### In Claude Code

1. Type `/skills` and confirm `auto-git-workflow` appears in the list.
2. If missing, verify `.claude/skills/auto-git-workflow/SKILL.md` exists and restart Claude Code.

### In Google Antigravity

1. In the agent CLI, check `.agents/skills/` to confirm `auto-git-workflow` and `auto-git-workflow-cmd` are present.
2. Check `.agents/hooks.json` to verify the `agy-block-dangerous-git` hook entry exists.
