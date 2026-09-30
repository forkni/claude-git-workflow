# CGW git-workflow — known issues & fix roadmap

Audit of the `scripts/git/` wrappers + `_common.sh` / `_config.sh`, 2026-07. Triggered by two bugs
found and fixed in `commit_enhanced.sh` (`dbd3b0e`, `494fc0c`): a lint gate that silently scanned the
whole repo, and a fragile arg-parsing helper. This catalogues **similar** gaps found elsewhere.

Nothing here is fixed yet (except where noted). Severities are calibrated against real failure
scenarios, not worst-case. Line numbers verified 2026-07; re-grep before editing.

**Fix-difficulty legend:** 🟢 safe/small · 🟡 non-trivial or behavior-changing · 🔴 larger structural.

---

## HIGH

### F1 · No automated tests for the bash safety layer 🔴 — ADDRESSED in this repo (2026-09-29)

> **Status:** `tests/test_cgw_git.py` (+ `tests/cgw_sandbox.py`) now covers the items below against
> disposable git repos with a local bare `origin` — `python -m unittest discover -s tests`, run in
> CI. Covered: the local-file matcher (spaces/unicode/dir-prefix/exempt), the commit-message grammar,
> the branch predicates, backup tags, stale-`index.lock` handling, `commit_enhanced.sh` (the staging
> matrix, `--only`, local-file exclusion, freeform branches), `push_validated.sh`,
> `undo_last.sh`, `merge_with_validation.sh` (incl. the local-file merge guard), and an
> argument-handling contract over every script. Mutation-checked: 11/11 deliberate bugs are caught.
> `rollback_merge.sh`, `cherry_pick_commits.sh` and `recover.sh` are covered by
> `tests/test_cgw_recovery.py` (mutation-checked: 10/10 deliberate bugs caught).
> **Not yet covered in this repo's Python unit tests:** conflict classification/resolution internals, `rebase_safe`, `worktree_manage`,
> and the lint/format stages (disabled in the sandbox).
> **Note on upstream testing:** Upstream `claude-git-workflow` is the canonical test home, maintaining a 35-file Bats suite (`tests/integration/*.bats` and `tests/unit/*.bats`) running via `tests/run.sh` covering 28+ of the 31 scripts.
> The original finding is kept below for the record.

**Where:** entire `scripts/git/` (no `*.bats`, no `--selftest` in any `.sh` — verified).
**Problem:** The Python half of this repo ships `--selftest` on every script; the ~20 mutating git
wrappers and `_common.sh` (conflict classification, `cgw_filter_local_files`, the 4-way staging
decision matrix, `--only` handling, stale-`index.lock` removal) have **zero** automated coverage.
Every other finding below is the kind of bug a test suite catches on the first run.
**Failure scenario:** a refactor of `cgw_filter_local_files` or the staging matrix silently regresses;
nothing fails until a local-only file lands in a real commit.
**Fix:** a `bats` suite (or per-script `--selftest`) covering: the staging matrix (all 4
pre-staged×unstaged combos), local-file filtering with spaces/unicode/dir-prefix entries, `--only`
reset-failure, conflict classification with malformed `status --porcelain`. **Do this first** if
fixing several others — it turns every fix below into a regression-guarded change.

---

## MEDIUM

### A1 · Markdown-lint commit gate runs whole-repo 🟡

**Where:** `commit_enhanced.sh:448` (bare call) → `_common.sh:974` → `_config.sh:138`.
**Problem:** `cgw_run_markdownlint_check` is called with no files → whole-repo `**/*.md` scan. Can't
be scoped by passing files, because `CGW_MARKDOWNLINT_ARGS` (`**/*.md !CLAUDE.md !MEMORY.md`)
conflates the scan-target glob with exclusions, so explicit files are *appended* to the glob, not
substituted. Sibling of the Python-lint bug already fixed.
**Failure scenario:** an unrelated markdown file elsewhere in the repo has a lint violation; a
code-only commit is blocked by the gate.
**Fix:** split config into `CGW_MARKDOWNLINT_PATHS` (replaceable target) + `CGW_MARKDOWNLINT_ARGS`
(flags/exclusions), scope via `cgw_modified_files_for_lint staged "*.md"`. Full write-up:
**see `markdownlint-scoping.md`.** Deferred because it's behavior-changing for existing
`CGW_MARKDOWNLINT_CMD` users and untestable here (unset in this repo).

### A2 · `cgw_run_typecheck` has the same bare-call whole-repo path 🟡 (latent)

**Where:** `_common.sh:995`, whole-repo branch at `:1014`.
**Problem:** identical shape to the lint/markdown bug — no-args → whole-repo typecheck. **Not wired
into the commit gate today**, so it can't misfire yet, but any future typecheck gate inherits it.
**Fix:** when a caller scopes it, pass files + `cgw_strip_path_arg` (the lint path already does this
at `_common.sh:868`). Combine with the A3 placeholder fix below.

### A3 · `cgw_strip_path_arg` still assumes the path is a trailing `.` 🟡

**Where:** `_common.sh:836` (already hardened in `494fc0c` — this is the *residual* limitation).
**Problem:** it now strips only an exact trailing `.`. That's safe, but any `CGW_LINT_*_ARGS` whose
path token isn't the exact last token defeats file-scoping and **silently reverts to a whole-repo
scan**: e.g. `CGW_LINT_CHECK_ARGS="check . --fix"` → not stripped → `ruff check . --fix file1.py`
scans both `.` (whole repo) *and* the file. `check src/` (non-dot path) has the same issue.
**Failure scenario:** a project customizes the lint args in a reasonable-but-non-default shape; the
commit gate silently goes back to whole-repo, reintroducing the original bug via config.
**Fix:** replace the positional-`.` convention with an explicit `{files}` placeholder token that
callers substitute (or append when absent). Removes the "must end in `.`" assumption for lint,
format, and typecheck args uniformly.

### C1 · Local-file protection isn't applied at merge / cherry-pick / amend 🟡 — FIXED (2026-09-29)

> **Status (2026-09-29, verified by Bats integration tests):** FIXED.
>
> - `merge_with_validation.sh` and `cherry_pick_commits.sh` enforce `cgw_guard_incoming_local_files` to block incoming commits carrying local-only files.
> - `undo_last.sh amend-message` inspects staged index changes: hard-refuses (`exit 1`) if local-only files are staged, and warns/prompts (or aborts in non-interactive mode) if non-local staged changes exist.
> - Verified by `merge_validation.bats`, `cherry_pick.bats`, and `undo_last.bats`.

**Where:** `merge_with_validation.sh:328` (clean merge), `:352` (conflict-conclusion commit), `:139`
(docs-CI amend); `cherry_pick_commits.sh:280`; `undo_last.sh:391` (`amend-message`).
**Problem:** `commit_enhanced.sh` unstages `CGW_LOCAL_FILES` (`CLAUDE.md`, `MEMORY.md`, `.claude/`,
`logs/`) before every commit. These other commit-producing paths do **not** — same class as the
original bug (a guard present in one place, missing elsewhere). A local-only path that reached a
commit on the source branch, or a non-gitignored exempt file, can propagate into the merge/pick/amend.
**Failure scenario:** a feature branch accidentally committed `.claude/settings.local.json`; merging
it to the target propagates that local-only file into the target's history.
**Severity note:** probability-gated — these paths are usually gitignored, so real exposure is low.
**Fix (non-trivial, differs from commit's):** you can't "unstage" from a merge. Needs *pre-merge*
detection (inspect the incoming diff for `cgw_is_local_file` matches; abort/warn) or a post-commit
amend-out. Design before implementing — **do not quick-fix.**

### D1 · `--only` reset failure is swallowed 🟢 — FIXED (2026-09-29)

> **Status (2026-09-29):** FIXED. `commit_enhanced.sh` checks exit code of `git reset HEAD`; if it fails and HEAD is not unborn (`git rev-parse --verify HEAD`), it aborts cleanly. Verified by `tests/integration/commit_enhanced.bats`.

**Where:** `commit_enhanced.sh:265` — `git reset HEAD >/dev/null 2>&1 || true`.
**Problem:** `--only` promises "reset the index, then stage exactly these paths." If the reset fails
(index lock, or an unborn HEAD on a fresh repo), `|| true` swallows it and staging proceeds on top of
whatever was already staged — committing more than the explicit `--only` set. A silent contract
violation.
**Failure scenario:** a transient `index.lock` makes the reset fail; the user's `--only foo.py` commit
also includes unrelated pre-staged files.
**Fix:** capture the exit code; if reset fails for a reason other than "unborn HEAD" (`git rev-parse
--verify HEAD` to distinguish), abort with a clear error instead of proceeding.

### E1 · `rollback_merge.sh --hard` takes no pre-rollback backup tag 🟢 — FIXED (2026-09-29)

> **Status (2026-09-29, verified by `tests/integration/rollback_merge.bats`):** FULLY FIXED.
>
> - `rollback` was added to `CGW_BACKUP_OPS` and `rollback_merge.sh` creates a `pre-rollback-*` backup tag pointing at the discarded HEAD.
> - In `--non-interactive` mode, hard rollback explicitly refuses (`exit 1`) when `--target` is omitted and no `pre-merge-*` backup tag exists, preventing accidental fallbacks to `HEAD~1`.

**Where:** `rollback_merge.sh:316` (`reset --hard "${rollback_target}"`), confirm at `:262`;
`CGW_BACKUP_OPS` at `_common.sh:439` (note: `rollback` is **absent** from the list).
**Problem:** `rebase_safe.sh` and `undo_last.sh` create a backup tag *before* their destructive op;
rollback's `--hard` path discards the current HEAD with none. Reflog-recoverable and token-gated
interactively — **but** the confirm is `cgw_confirm ... --literal-token ROLLBACK --non-interactive
accept`, so `--non-interactive` **auto-accepts without the token**, and with no `--target` and no
existing backup tag it falls back to `HEAD~1`.
**Failure scenario:** `rollback_merge.sh --non-interactive` in a script, no `--target`, no
`pre-merge-*` tag present → silently hard-resets the target branch to `HEAD~1` with no backup of what
was discarded.
**Fix:** add `rollback` to `CGW_BACKUP_OPS` and `cgw_create_backup_tag rollback` before the reset;
reconsider whether `--non-interactive` should default to `abort` (not `accept`) for a `--hard`
rollback. The `--revert` mode (safe default alternative) is unaffected.

---

## LOW

### D2 · Push behind-check fetch failure is swallowed 🟢 — FIXED (2026-09-29)

> **Status (2026-09-29):** FIXED. `push_validated.sh` prints an explicit warning on fetch failure and refuses to treat stale remote tracking refs as trusted. Verified by `tests/integration/push_validated.bats`.

**Where:** `push_validated.sh:172` — `git fetch ... || true`.
**Problem:** the "is local behind remote?" guard runs after this fetch; if the fetch fails
(network/auth), the check runs against stale tracking refs and can silently pass, so the guard is
skipped.
**Fix:** on fetch failure, print an explicit warning (or fail) so the behind-check result isn't
trusted on stale data.

### D3 · Unstage-loop reset swallow — MITIGATED (informational) 🟢

**Where:** `commit_enhanced.sh:76` — `git reset HEAD "${f}" 2>/dev/null || true`.
**Problem:** a failed unstage of a local-only file is swallowed. **Mitigated:** a hard post-unstage
verification (`commit_enhanced.sh` re-checks staged files against `cgw_filter_local_files` and exits

1) catches a leaked local file before the commit. Recorded so the swallow isn't "fixed" in isolation
without noticing the downstream guard.

### F2 · Config defaults scattered in callers, not `_config.sh` 🟢 — FIXED (2026-09-29)

> **Status (2026-09-29):** FIXED. All runtime gate defaults centralized with `[[ -z "${VAR+x}" ]] && VAR=default` in `_config.sh` and tracked in `_CGW_REGISTRY`. Verified by `tests/unit/config_registry.bats`.

**Where:** `CGW_SKIP_LINT`, `CGW_SKIP_MD_LINT`, `CGW_SKIP_TYPECHECK`, `CGW_TYPECHECK_CMD`,
`CGW_TYPECHECK_CHECK_ARGS`, `CGW_TYPECHECK_EXCLUDES`, `CGW_ALL` — used via `${VAR:-default}` in
callers; **none defined in `_config.sh`** (verified: 0 occurrences).
**Problem:** works today, but there's no single source of truth — a future caller that forgets the
`:-default` fallback gets an empty string silently (and with `set -u`, an *unguarded* bare `${VAR}`
would error). Maintainability/consistency risk, not a live bug.
**Fix:** centralize with `[[ -z "${VAR+x}" ]] && VAR=default` in `_config.sh`, matching how
`CGW_LINT_CMD` etc. are already defined there.

---

## Observations from the F1 test work (2026-09-29) — ALL FIXED (2026-09-29)

- **Obs 1 (`commit_enhanced.sh` & `undo_last.sh`)**: The "Configured types" line prints `feat, fix, docs, chore, ...` using `${CGW_ALL_PREFIXES//|/, }` (all `|` separators replaced by commas).
  - *Verified by*: `tests/integration/commit_enhanced.bats`, `tests/integration/undo_last.bats`.
- **Obs 2 (`commit_enhanced.sh`)**: Committing when *only* local-only files were modified exits 0 cleanly with explanatory message (`[!] No changes to commit (tracked changes were in local-only files and were excluded)`).
  - *Verified by*: `tests/integration/commit_enhanced.bats`.
- **Obs 3 (`merge_with_validation.sh`)**: Clean merges untrap cleanly and remain on target branch without spurious `[!] Interrupted` output.
  - *Verified by*: `tests/integration/merge_validation.bats`.
- **Obs 4 (`merge_with_validation.sh`)**: Trap `_cleanup_merge` detects `MERGE_HEAD` and reports paused conflict resolution state instead of claiming false return to source.
  - *Verified by*: `tests/integration/merge_validation.bats`.
- **Obs 5 (`merge_with_validation.sh`)**: `cgw_guard_incoming_local_files` executes *before* `cgw_create_backup_tag`, so a refused merge leaves no stray `pre-merge-*` backup tag.
  - *Verified by*: `tests/integration/merge_validation.bats`.
- **Obs 6 (`check_local_files.sh`)**: Added standard CLI option parser: `--help`/`-h` exits 0 with usage, unknown flags exit 1.
  - *Verified by*: `tests/integration/check_local_files.bats`.
- **Obs 7 (`recover.sh restore`)**: Validates branch name syntax via `git check-ref-format --branch` *before* creating `pre-recover-*` backup tag, preventing stray tags on invalid input.
  - *Verified by*: `tests/integration/recover.bats`.
- **Obs 8 (`cherry_pick_commits.sh`)**: Redundant cherry-picks (commit already applied on target branch) are detected (`git diff --cached --quiet` with zero unmerged conflicts); the script auto-aborts the pick, returns to the original branch, and exits 1 with an actionable error.
  - *Verified by*: `tests/integration/cherry_pick.bats`.

## Fixed after the audit

### R1 · `rollback_merge.sh --revert` could revert a non-merge commit (root commit) — FIXED here 🟢

`parent_count=$(… | grep -c "^parent " || echo "0")`: for a commit with no parents `grep -c` prints `0`
*and* exits 1, so `|| echo "0"` made the value `"0\n0"`, the `[[ … -lt 2 ]]` guard raised a syntax
error instead of refusing, and `git revert -m 1` ran on the root commit — deleting the repository's
base files while reporting `REVERT SUCCESSFUL`. Fix: `|| true`. Regression test:
`test_revert_refuses_when_the_target_is_a_root_commit`. **Upstream-applicable** (vendored script).

### R2 · `recover.sh reflog` doubled its output and printed a false "no reflog entries" — FIXED here 🟢

`git reflog … | head -n N || <fallback> | head -n N || { "(no reflog entries)" }` under `pipefail`:
`head` closes the pipe, `git` exits 141, so whenever the reflog is longer than the limit (default 20,
i.e. any real repo) every `||` fallback ran. Fix: decide on the captured text. Regression test:
`test_reflog_lists_entries_honours_limit_and_shows_backup_tags`. **Upstream-applicable.**

### A4 · File-scoped lint bypassed ruff's `(extend-)exclude` — FIXED in this repo, upstream-applicable 🟢

**Where:** `_config.sh` ruff arg defaults (fix); interaction between the staged-file gate
(`commit_enhanced.sh`) / `--modified-only` and ruff's exclude semantics.
**Problem (found in post-fix review):** ruff applies `exclude`/`extend-exclude` only to paths it
*discovers* by directory traversal; **explicitly-passed files bypass the excludes** unless
`--force-exclude` is set. The old whole-repo `.` scan honored `ruff.toml` excludes; the file-scoped
gate passes staged files explicitly — so staging a `.py` under an excluded directory got it linted
and (in the non-interactive auto-fix path) reformatted against the project's own lint config.
**Fix applied:** `--force-exclude` added to all four ruff arg defaults
(`CGW_LINT_CHECK_ARGS`, `CGW_LINT_FIX_ARGS`, `CGW_FORMAT_CHECK_ARGS`, `CGW_FORMAT_FIX_ARGS`).
Harmless on whole-repo scans; makes explicit-file calls honor the same excludes as traversal.
Verified: a deliberately-broken staged file under an excluded dir is skipped ("No Python files
found"), a repo-root one is still flagged. Projects that override these args in `.cgw.conf` should
add the flag to their overrides too.

## Non-findings (checked clean — recorded so they aren't re-audited)

- **No blind conflict resolution.** No `git checkout --ours/--theirs` or `-X ours|theirs` auto-merge
  anywhere; `merge_with_validation.sh` only uses `--conflict=` (marker style) and optional
  `-Xignore-space-change`. Conflicts route through `cgw_resolve_safe_conflicts` (manual investigation).
- **Force-push is guarded.** `push_validated.sh` uses `--force-with-lease` (not `--force`) and
  requires a literal-token confirmation for protected branches.
- **Shell strictness is consistent.** Every executable wrapper sets `set -uo pipefail`; the two
  sourced libraries (`_common.sh`, `_config.sh`) intentionally don't (callers own strictness).
  `commit_enhanced.sh` omits `-e` deliberately (it relies on `git diff` exit codes for signalling).
- **`cgw_is_local_file` matching is correct.** `[[ "$path" == "$dir"/* ]]` is proper bash glob
  matching (an earlier audit pass misread this as fragile); exact-match for non-dir entries, prefix
  match for trailing-slash dir entries. No bug.

---

## Fix roadmap — Status Summary (2026-09-29)

- **Completed & Verified:**
  - **Structural foundation:** F1 (35-file Bats test suite in upstream repository; extensive Python integration test harness).
  - **Scoping & Quality Gates:** A1 (markdownlint file scoping), A2 + A3 (typecheck file scoping + `{files}` placeholder support).
  - **Local-only & Index Safety:** C1 (local-file protection at merge, cherry-pick, and amend-message).
  - **Error handling & Safeguards:** D1 (`--only` reset verification), E1 (`rollback_merge.sh --hard` backup tag + non-interactive refusal), F2 (`_config.sh` centralized defaults), D2 (push behind-check fetch warning).
  - **Operational & CLI ergonomics:** Obs 1 through Obs 8 (all fixed and verified in integration tests).

All fixes apply to the upstream source at `github.com/forkni/claude-git-workflow`; the copy under
`scripts/git/` here is vendored from it.
