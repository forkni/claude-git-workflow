# Claude Code Integration

## How It Works

CGW includes a Claude Code **skill** that teaches Claude to use `scripts/git/*.sh` wrapper scripts instead of raw `git` commands. This ensures lint checks, local-file protection, and backup tags are never bypassed when Claude performs git operations.

It also includes a `/auto-git-workflow` **slash command** that runs the full commit → push → merge → push workflow in one step.

---

## Automatic Installation

`install.cmd` (Windows) and `configure.sh` (Unix) install the skill and slash command automatically during project setup.

After installation, Claude Code will automatically enforce the workflow rules — no `/auto-git-workflow` invocation needed for individual operations.

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
- Slash command: `~/.claude/commands/auto-git-workflow.md`

**Local install locations (default):**
- Skill: `.claude/skills/auto-git-workflow/`
- Slash command: `.claude/commands/auto-git-workflow.md`

Note: `.claude/` is git-ignored, so the skill is local to each developer's machine.

---

## Manual Installation

If `configure.sh` was run with `--skip-skill`, install manually:

```bash
# Local (project-only)
cp -r skill/ .claude/skills/auto-git-workflow/
cp command/auto-git-workflow.md .claude/commands/

# Global (all projects)
cp -r skill/ ~/.claude/skills/auto-git-workflow/
cp command/auto-git-workflow.md ~/.claude/commands/
```

---

## Using `/auto-git-workflow`

The `/auto-git-workflow` slash command runs the full promotion workflow:

1. Pre-commit validation (branch, lint check)
2. Commit to source branch
3. Push source branch
4. Merge source → target (or create PR, depending on `CGW_MERGE_MODE`)
5. Push target branch

Run it in Claude Code:

```
/auto-git-workflow
```

Claude will execute each step using the wrapper scripts and report results.

---

## Verifying the Skill

In Claude Code, type `/skills` to list loaded skills. `auto-git-workflow` should appear in the list.

If it's missing:
1. Check that `.claude/skills/auto-git-workflow/SKILL.md` (or `~/.claude/skills/auto-git-workflow/SKILL.md`) exists
2. Restart Claude Code to reload skills
3. Re-run `./scripts/git/configure.sh` if the files are missing
