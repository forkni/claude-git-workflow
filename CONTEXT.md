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

## backup tag

An annotated git tag recording the state of a branch immediately before a mutating CGW operation. Format: `pre-<op>-<YYYYMMDD_HHMMSS>-<pid>`. Created by `cgw_create_backup_tag <op>` before any merge, cherry-pick, rebase, bisect, or undo-commit. Enables `git reset --hard <tag>` rollback.

**Implementation seam**: `cgw_create_backup_tag` / `cgw_list_backup_tags` in `scripts/git/_common.sh`.
