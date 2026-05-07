# CGW Domain Glossary

Terms defined here pin the language used in architecture reviews, code comments, and PR descriptions. When a term appears in code, use the spelling here exactly.

---

## conflict policy

The deterministic mapping from a `git status --short` two-letter porcelain pair → (category, auto-resolve action OR halt template).

**Porcelain pair semantics** (column 1 = index/staging state, column 2 = working-tree state):

| Pair | Category | Disposition |
|------|----------|-------------|
| `DU` | modify/delete | Auto-resolve: `git rm` (we deleted, theirs modified) |
| `DD` | both deleted | Auto-resolve: `git rm` |
| `UU` | both modified | Halt: content conflict, manual edit required |
| `AU` | add/unmerged | Halt: add-side conflict |
| `AA` | both added | Halt: add-side conflict |
| `UD` | deleted by them | Halt: accept deletion (`git rm`) or keep ours (`git add`) |
| `AD` | added by us, deleted by theirs | Halt: keep-ours vs keep-theirs |
| `DA` | deleted by us, added by theirs | Halt: keep-ours vs keep-theirs |

**Implementation seam**: `cgw_classify_conflicts` (pure classifier, injectable fixture) and `cgw_resolve_safe_conflicts` (impure resolver, owns halt messages and op-specific recovery footers) in `scripts/git/_common.sh`.

**Callers**: `merge_with_validation.sh`, `cherry_pick_commits.sh` (both use `cgw_resolve_safe_conflicts`); `rebase_safe.sh` (read-only — uses `cgw_classify_conflicts` + `cgw_print_conflict_summary` for display only, never auto-resolves mid-rebase).

---

## local-only file

A file or directory that must never be committed to the remote repository. Configured via `CGW_LOCAL_FILES` in `.cgw.conf`. Match contract: literal name or trailing-slash directory entry, anchored on both ends — no globs, no substring matches.

**Implementation seam**: `cgw_is_local_file` / `cgw_filter_local_files` in `scripts/git/_common.sh`.

---

## lint pipeline

The shared module responsible for running lint, format, and markdownlint tool binaries against staged or modified files. Lives in `_common.sh` and is reused by `commit_enhanced.sh`, `check_lint.sh`, `fix_lint.sh`, and the pre-commit hook.

**Key seams**:
- `cgw_resolve_lint_binary <cmd>` — pure venv-aware path resolver. Given a binary name (e.g., `ruff`), returns the absolute venv path when it exists, or the bare name for system PATH lookup. Reads `PYTHON_BIN` / `PYTHON_EXT` (pre-populated by `get_python_path`). No side effects.
- `run_tool_with_logging <section-name> <logfile> <cmd> [args…]` — runs a tool, captures stdout+stderr, writes to the named log section via `log_section_start`/`log_section_end`, returns the tool's exit code. Used by all lint/format/markdownlint invocations.

**Callers**: `commit_enhanced.sh` (lint check, format check, markdownlint, auto-fix loop), `check_lint.sh`, `fix_lint.sh`, `.githooks/pre-commit` (non-blocking advisory check).

---

## commit-message format

The conventional-commit grammar enforced on every `commit_enhanced.sh` invocation and every commit in the pre-push hook range. Format: `<type>: <description>` where `<type>` is drawn from the built-in set (`feat|fix|docs|chore|test|refactor|style|perf`) plus any `CGW_EXTRA_PREFIXES` configured in `.cgw.conf`.

**Implementation seam**: `cgw_validate_commit_message <msg>` in `scripts/git/_common.sh`. Pure predicate — returns 0 on match, 1 otherwise. No output: each caller owns its own user-facing message and merge-commit skipping logic.

**Callers**: `commit_enhanced.sh` (step [5]), `undo_last.sh` (amend-message path), `.githooks/pre-push` (all commits in push range).

---

## backup tag

An annotated git tag recording the state of a branch immediately before a mutating CGW operation. Format: `pre-<op>-<YYYYMMDD_HHMMSS>-<pid>`. Created by `cgw_create_backup_tag <op>` before any merge, cherry-pick, rebase, bisect, or undo-commit. Enables `git reset --hard <tag>` rollback.

**Implementation seam**: `cgw_create_backup_tag` / `cgw_list_backup_tags` in `scripts/git/_common.sh`.
