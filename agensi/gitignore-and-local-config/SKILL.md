---
name: gitignore-and-local-config
description: Composes a correct .gitignore from curated stack templates (Python, Node/TypeScript, Rust, Go, C/C++, CUDA) plus OS, editor and AI-agent rules, and keeps secrets and machine-local config out of git. Use when creating or fixing a .gitignore, when a file is ignored or not ignored unexpectedly, when an already-tracked file must stop being tracked, or when adding a config file that holds credentials.
---

# .gitignore and Local Config

Templates and precedence rules: [references/gitignore-templates.md](references/gitignore-templates.md).
Secrets and local config: [references/secrets-and-local-config.md](references/secrets-and-local-config.md).

## Composing a .gitignore

1. Detect the stack from the repo (`pyproject.toml`, `package.json`, `Cargo.toml`, `go.mod`,
   `CMakeLists.txt`, `*.cu`) and start from that stack's template in the reference. Merge a few
   templates only when the repo really mixes stacks.
2. Add the baseline block for logs, `.env` files and machine-local config.
3. Keep OS and editor rules (`.DS_Store`, `.idea/`, `.vscode/`) in the user's global excludes file
   (`core.excludesFile`), not the repo, unless the team can't rely on everyone having one.
4. Treat agent files (`CLAUDE.md`, `AGENTS.md`, `.claude/`, `.cursor/`) as a per-project choice.
   Many teams commit them on purpose, so ask before ignoring them.
5. Edit the existing `.gitignore` in place. Never reorder or drop rules the project already has.

## Rules that catch people

- **Last matching pattern wins**, and a negation (`!path`) can't re-include a file whose parent
  directory is excluded. Exclude `dir/*`, not `dir/`, when you need a carve-out.
- **`.gitignore` does nothing for tracked files.** To stop tracking a file but keep it on disk:
  add the pattern, run `git rm --cached <path>`, then commit. Never use plain `git rm` or
  `git rm -f` for this, because both delete the working copy.
- **Debug with `git check-ignore -v <path>`.** It prints the winning `file:line:pattern`. Add
  `--no-index` for a path that is already tracked.

## Secrets

- Real values go in a gitignored file. Commit only an `*.example` copy with placeholders.
- A secret that was ever committed or pushed must be **rotated at its source**. Untracking it, or
  rewriting history, only hides it from the current tree. Tell the user this plainly, and never
  rewrite shared history without their explicit go-ahead.

Source and full toolkit: <https://github.com/forkni/claude-git-workflow> (MIT).
