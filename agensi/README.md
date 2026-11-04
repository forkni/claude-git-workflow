# Standalone Agent Skills (Agensi listings)

Sources for the portable skills built from this repo and listed for free on
[Agensi](https://www.agensi.io). Each one is a single Agent Skills folder (`SKILL.md` with
`name` and `description` frontmatter, plus optional `references/`, `scripts/`, `assets/`), so the
same zip works in Claude Code, Codex, Cursor, Copilot and other agents that read `SKILL.md`. They
carry none of the Claude Code-only parts of the main install: no hooks, no slash command, no
`.claude/` paths, no agent-specific frontmatter.

| Skill | Ships | Built from |
|---|---|---|
| `gitignore-and-local-config` | `SKILL.md`, 2 references | portable copies in this folder |
| `git-merge-conflict-resolution` | `SKILL.md`, 2 references | portable copies in this folder |
| `safe-git-workflow` | `SKILL.md`, 5 references, 24 scripts, `assets/cgw.conf.example` | `SKILL.md` here; references, scripts and config copied from the repo at build time |

## Build

```bash
bash scripts/dev/build_agensi.sh            # all skills, into dist/agensi/ (gitignored)
bash scripts/dev/build_agensi.sh --list     # skill names
bash scripts/dev/build_agensi.sh safe-git-workflow --out /tmp/agensi
```

Each skill comes out as `dist/agensi/<name>/` (the unpacked tree, for review) and
`dist/agensi/<name>.zip` (the upload). The build fails when a check fails:

- frontmatter `name` matches the folder, `description` is present and under 1024 characters, and
  no agent-specific frontmatter (`allowed-tools`, `user-invocable`, `hooks`, ...) is used;
- no Claude Code-only or vendored-path terms remain in the Markdown;
- every relative link resolves inside the zip, and every script the docs name ships;
- every script passes `bash -n` and is executable.

It also lists the lines that marketplace security scanners commonly flag (`rm -rf`,
`reset --hard`, `--force-with-lease`, `npx`, ...) for a human to review. That list is information,
not a failure: the remaining hits are the backup-tag rollbacks and lease-guarded pushes the
toolkit exists for.

`tests/integration/build_agensi.bats` builds every skill and checks the result.

## What the build changes (packaged copies only)

- `./scripts/git/<x>.sh` in the shipped Markdown becomes `<skill-dir>/scripts/<x>.sh`. The scripts
  find the repository from the working directory, so they run from the skill folder unchanged.
- Sections about scripts the zip doesn't ship (PRs, CI gate, releases, worktrees, setup) and the
  Claude Code guardrail are dropped from the references; links to references the zip doesn't
  ship point at their GitHub copy.
- `CGW_MARKDOWNLINT_NPX_FALLBACK` defaults to `0`, so a packaged skill never downloads an npm
  package by itself. Users can set it to `1` in `.cgw.conf`.

## Keeping the portable copies current

The two knowledge-only skills keep their own edited copies of four canonical references, rewritten
without CGW-specific steps. When you change one of these in `skill/references/`, update its copy
here too:

| Canonical | Portable copy |
|---|---|
| `gitignore-templates.md` | `gitignore-and-local-config/references/gitignore-templates.md` |
| `secrets-and-local-config.md` | `gitignore-and-local-config/references/secrets-and-local-config.md` |
| `resolving-merge-conflicts.md` | `git-merge-conflict-resolution/references/resolving-merge-conflicts.md` |
| `git-recipes.md` | `git-merge-conflict-resolution/references/git-recipes.md` |

`safe-git-workflow` reads the canonical references and scripts directly, so it only needs a rebuild.
