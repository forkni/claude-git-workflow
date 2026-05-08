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
- `cgw_run_lint_check [files…]` — runs `CGW_LINT_CMD` with `CGW_LINT_CHECK_ARGS` (and optional file list) via `run_tool_with_logging`. Skips silently when `CGW_SKIP_LINT=1` or `CGW_LINT_CMD` is empty.
- `cgw_run_format_check [files…]` — runs `CGW_FORMAT_CMD` with `CGW_FORMAT_CHECK_ARGS` via `run_tool_with_logging`. Skips silently when `CGW_FORMAT_CMD` is empty.
- `cgw_run_lint_fix [files…]` — bundled lint+format fix: runs lint `--fix` then format `--fix` in sequence. Skips silently when both CMDs are empty.
- `cgw_run_markdownlint_check [files…]` — runs `CGW_MARKDOWNLINT_CMD` with `CGW_MARKDOWNLINT_ARGS` via `run_tool_with_logging`. Skips silently when `CGW_SKIP_MD_LINT=1` or `CGW_MARKDOWNLINT_CMD` is empty.
- `cgw_strip_path_arg <args-string>` — strips the trailing path token from a CGW args string (the `${ARGS% *}` idiom). Used when a file list is passed explicitly so the default path token doesn't conflict.
- `cgw_modified_files_for_lint` — returns the space-separated list of `.py` files modified vs HEAD (for `--modified-only` mode in `check_lint.sh` / `fix_lint.sh`).

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

---

## interactive confirmation

The shared module for all binary yes/no confirmation prompts in CGW scripts. Concentrates a seam previously scattered across 35+ inline `read -r -p` sites in 15 scripts, with inconsistent non-interactive policy at each site.

**Implementation seam**: `cgw_confirm <prompt> [options]` in `scripts/git/_common.sh`.
- Default mode: reads a line from stdin; `yes` → returns 0, anything else → returns 1.
- `--default yes|no`: maps an empty answer to confirmed or denied.
- `--literal-token TOKEN`: requires the literal token (e.g., `CLEAR`, `FORCE`, `ROLLBACK`) instead of `yes/no` — used for destructive-operation double-confirms.
- `--non-interactive abort|accept|deny`: explicit non-interactive policy declared at the call site. When `CGW_NON_INTERACTIVE=1`: `abort` prints a message and exits 1; `accept` returns 0 silently; `deny` returns 1 silently. Callers own the `CGW_NON_INTERACTIVE=1` assignment from their `[[ ! -t 0 ]]` check — `cgw_confirm` does not test TTY internally.

**Callers**: every binary confirmation prompt in `bisect_helper.sh`, `branch_cleanup.sh`, `cherry_pick_commits.sh`, `commit_enhanced.sh`, `configure.sh`, `create_release.sh`, `merge_docs.sh`, `merge_with_validation.sh`, `push_validated.sh`, `rebase_safe.sh`, `rollback_merge.sh`, `setup_attributes.sh`, `stash_work.sh`, `sync_branches.sh`, `undo_last.sh`. The 3-way `(yes/no/skip)` prompt in `commit_enhanced.sh` stays inline — the helper is binary only.
