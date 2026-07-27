# Claude Code Integration

## How It Works

CGW includes a Claude Code **skill** that teaches Claude to use `scripts/git/*.sh` wrapper scripts instead of raw `git` commands. This ensures lint checks, local-file protection, and backup tags are never bypassed when Claude performs git operations.

It also includes a `/auto-git-workflow-cmd` **slash command** — a state-aware interactive
menu covering every git operation (commit, push, sync, merge, PR, undo, release, and more).
Before showing the menu it scans the repo (uncommitted work, ahead/behind counts,
in-progress merge/rebase, stashes) and suggests the likely next step — e.g. a dirty tree
suggests committing, an ahead-only branch suggests pushing. It also offers a one-click
"Full promotion" shortcut that runs the full commit → push → merge → push workflow. Every
push it performs is followed by a mandatory CI verification gate — see
[`ci-setup.md`](ci-setup.md#ci-verification-gate).

---

## Automatic Installation

`cgw-install.cmd` (Windows) and `configure.sh` (Unix) install the skill and slash command automatically during project setup.

After installation, Claude Code will automatically enforce the workflow rules — no `/auto-git-workflow-cmd` invocation needed for individual operations.

---

## Global vs Local Installation

By default, the skill installs into the **project's** `.claude/` directory — it's only active when Claude Code is opened in that project.

Use `--global` to install into `~/.claude/` instead, making the skill available **in every project**:

```bash
# Install globally (available in all projects)
./scripts/git/configure.sh --skip-hooks --global

# Or during initial configure
./scripts/git/configure.sh --global
```

**Global install locations:**
- Skill: `~/.claude/skills/auto-git-workflow/`
- Slash command: `~/.claude/commands/auto-git-workflow-cmd.md`

**Local install locations (default):**
- Skill: `.claude/skills/auto-git-workflow/`
- Slash command: `.claude/commands/auto-git-workflow-cmd.md`

Note: `.claude/` is git-ignored, so the skill is local to each developer's machine.

---

## Manual Installation

If `configure.sh` was run with `--skip-skill`, install manually:

```bash
# Local (project-only)
cp -r skill/ .claude/skills/auto-git-workflow/
cp command/auto-git-workflow-cmd.md .claude/commands/

# Global (all projects)
cp -r skill/ ~/.claude/skills/auto-git-workflow/
cp command/auto-git-workflow-cmd.md ~/.claude/commands/
```

---

## Using `/auto-git-workflow-cmd`

The `/auto-git-workflow-cmd` slash command opens an interactive menu:

1. **⭐ Full promotion** — the full pipeline in one step: pre-commit validation, commit,
   push source, merge (or create PR, depending on `CGW_MERGE_MODE`), push target
2. **Commit & Stash**
3. **Push, Pull & Sync**
4. **Branch, Merge & PR**
5. **Undo & Recover**
6. **Release & Maintain**

Run it in Claude Code:

```
/auto-git-workflow-cmd
```

Pick an option (or describe what you want directly instead of picking a number), and
Claude will execute the matching wrapper script(s) and report results.

---

## Verifying the Skill

In Claude Code, type `/skills` to list loaded skills. `auto-git-workflow` should appear in the list.

If it's missing:
1. Check that `.claude/skills/auto-git-workflow/SKILL.md` (or `~/.claude/skills/auto-git-workflow/SKILL.md`) exists
2. Restart Claude Code to reload skills
3. Re-run `./scripts/git/configure.sh` if the files are missing

---

## How Claude decides to invoke the skill

Claude Code reads the `description:` field in `SKILL.md` and matches it against
the user's request. CGW's description names every wrapper-backed verb explicitly
(`commit`, `push`, `pull`, `fetch`, `merge`, `rebase`, `cherry-pick`, `rollback`,
`revert`, `sync`, `stash`, `tag`, `release`, `branch`, `bisect`, `undo`, `amend`).
Saying any of these in a request to Claude in a CGW-installed project should
auto-load the skill — no explicit `/auto-git-workflow-cmd` invocation needed.

If you suspect the skill isn't loading:

1. Ask Claude to run `/skills` and confirm `auto-git-workflow` is listed.
2. If listed but not auto-loading, mention the wrapper script by name in your
   request (e.g. "use commit_enhanced.sh to commit this") — that always pulls
   the skill in.
3. As a last resort, type `/auto-git-workflow-cmd` to force the router; it links
   back to SKILL.md so the rules load even if auto-invocation missed.

The skill's `description` is intentionally broad. To narrow it (e.g. exclude
read-only verbs), edit `description:` in the source `skill/SKILL.md` and
re-run `./scripts/git/configure.sh --skip-hooks` to redeploy.
