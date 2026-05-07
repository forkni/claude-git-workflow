# CGW — Architectural Deepening Status & Plans

> Tracking document for the multi-session architectural-deepening review of CGW
> (claude-git-workflow). Each candidate is a "deepening opportunity" surfaced
> by the `improve-codebase-architecture` skill. Order reflects what's been
> shipped and what's queued.

---

## Master status

| # | Candidate | Status | Commit |
|---|-----------|--------|--------|
| #2 | Backup-tag registry module (`cgw_create_backup_tag` / `CGW_BACKUP_OPS`) | DONE | `c070a22` |
| #1 | Local-only file matcher (`cgw_is_local_file` / `cgw_filter_local_files`) | DONE | `c44a6a0` |
| #7 | Conflict-resolution policy (`cgw_classify_conflicts` / `cgw_resolve_safe_conflicts` / `cgw_print_conflict_summary`) | DONE | `b05f30e` |
| **#6** | **`commit_enhanced.sh` phase extraction** | **NEXT SESSION** | — |

Test baseline: **362 bats tests passing** (`bats tests/unit/ tests/integration/`).
Branch: `development`, in sync with `origin/development`.

---

## Candidate #7 — Conflict-Resolution Policy (COMPLETED — `b05f30e`)

### What shipped

- Three new functions in `scripts/git/_common.sh` (~231 lines):
  - `cgw_classify_conflicts [<porcelain_override>]` — pure classifier, populates 8 category arrays + `CGW_CONFLICT_TOTAL`. Returns 0 when conflicts exist (so `if cgw_classify_conflicts; then` reads as "have conflicts"). Optional fixture-injection arg used by unit tests.
  - `cgw_resolve_safe_conflicts <op> <original_branch>` — owns the policy: auto-resolves DU/DD via `git rm`, re-classifies (fixes stale-snapshot bug), emits per-category halt messages with op-specific recovery footers (`merge` / `cherry-pick`). Sets `CGW_CONFLICT_STATE ∈ {none, resolved, unresolved}`.
  - `cgw_print_conflict_summary` — display helper for read-only call sites (rebase).
- Caller rewrites:
  - `scripts/git/merge_with_validation.sh` — old lines 343–442 (~96 LOC) collapsed to ~6-line caller.
  - `scripts/git/cherry_pick_commits.sh` — old lines 313–369 (~49 LOC) collapsed to ~13-line caller.
  - `scripts/git/rebase_safe.sh` — four `git diff --name-only --diff-filter=U` enumeration blocks replaced with `cgw_classify_conflicts || true; cgw_print_conflict_summary` (read-only adoption — rebase deliberately never auto-resolves mid-rebase).
- New `CONTEXT.md` at project root pinning the term "conflict policy" with the canonical porcelain-pair table.

### Drift bugs folded in (all closed)

1. **Cherry-pick generic halt → per-category parity** ✓ (cherry-pick now emits the same six per-category messages as merge).
2. **Merge stale-snapshot** ✓ — `cgw_classify_conflicts` is re-called after auto-resolve so halt checks see post-`rm` state, not the original snapshot.
3. **DD failure handling asymmetry** ✓ — both DU and DD loops now propagate `git rm` failure consistently via `resolution_failed=1`.
4. **`UD` semantics correction** (discovered during implementation, fixed in same commit) ✓ — `UD` = "Updated by us, **Deleted by them**", not "Deleted by us". Fixed: comment in globals declaration, error message text, recovery hints (now "Accept deletion" vs "Keep ours"), and `cgw_print_conflict_summary` label.

### Test count delta

`346 → 362` tests passing (`+16`, no regressions):
- `tests/unit/common.bats`: +9 unit tests for `cgw_classify_conflicts` (porcelain fixture injection — empty input, single per-category, all-categories, mixed, non-conflict prefixes ignored, blank lines, second-call reset).
- `tests/integration/merge_validation.bats`: +4 (DU auto-resolve exits 0; UU halt; UD halt; mixed DU+UU).
- `tests/integration/cherry_pick.bats`: +2 (UU halt with same message string as merge — drift parity proof; DU auto-resolve exits 1 with `--continue` hint).
- `tests/integration/rebase_safe.bats`: +1 (`--onto` UU conflict displays categorised summary with `(both modified)` suffix).

### Drift smoke (final state)

```
grep -rn 'git status --short\|--diff-filter=U' scripts/git/
```

→ Only `_common.sh` (the new module) plus 5 unrelated dirty-tree / status-display sites in `validate_branches.sh`, `create_release.sh`, `rollback_merge.sh`, `stash_work.sh`, `sync_branches.sh`. No missed conflict call sites.

### Files changed (`b05f30e`)

```
scripts/git/_common.sh                  | +231 / -0
scripts/git/cherry_pick_commits.sh      |  +6 / -55
scripts/git/merge_with_validation.sh    |  +6 / -102
scripts/git/rebase_safe.sh              |  +5 / -24
tests/integration/cherry_pick.bats      | +57 / -0
tests/integration/merge_validation.bats | +104 / -0
tests/integration/rebase_safe.bats      | +26 / -0
tests/unit/common.bats                  | +82 / -0
CONTEXT.md (new)                        | +51 / -0
```

Total: 9 files, +555 / -181.

---

## Candidate #6 — `commit_enhanced.sh` phase extraction (NEXT SESSION)

### Why it's queued

No detailed plan exists yet — Phase 1 exploration is still owed.

### Hypothesis (verify in Phase 1 — do not commit to it yet)

`scripts/git/commit_enhanced.sh` is the most-touched user-facing wrapper in CGW. It performs a sequence of phases inline:

1. Branch verification
2. Staged-files validation
3. Lint check (skippable via `--skip-lint`)
4. Local-only file unstaging (delegates to `cgw_filter_local_files`)
5. Conventional commit message format check
6. The actual `git commit`
7. Logging / summary block

Each phase is currently inline. Likely deepening opportunity: phase functions extracted (either into `_common.sh` or into a new `_commit_phases.sh`) so the orchestrator becomes thin (`run_phase_1 || exit 1; run_phase_2 || exit 1; …`) and individual phases become unit-testable in isolation.

Whether this is **actually** a deep refactor or a shallow one depends on Phase 1 findings — specifically, whether any phases are reused by other scripts (e.g., does `push_validated.sh` re-run lint? does `merge_with_validation.sh` re-validate staged state?). The deletion test will decide: would extracting phase X concentrate complexity, or just move it?

### Where to look first (seed for Phase 1 exploration)

```
scripts/git/commit_enhanced.sh        — primary site (orchestrator today)
scripts/git/check_lint.sh             — phase 3 (lint) lives here partly already
scripts/git/_common.sh                — local-only matcher already lives here (phase 4)
scripts/git/push_validated.sh         — does it duplicate phase 3?
tests/integration/commit_enhanced.bats — current behavioral baseline
.git/hooks/pre-commit                 — installed by configure.sh, may share logic
```

Search for: phase markers (`[1/`, `[2/`, etc.), the commit-format regex (`^(feat|fix|docs|chore|test|refactor|style|perf):`), the `--skip-lint` / `--skip-md-lint` / `--no-venv` / `--staged-only` flags, and any duplicated lint-invocation logic across scripts.

### Workflow for the next session

1. **EnterPlanMode**.
2. **Phase 1** — launch 1–3 `Explore` agents in parallel:
   - Agent A: map each phase in `commit_enhanced.sh` by line range; document inputs/outputs/side-effects.
   - Agent B: find duplication — does `push_validated.sh`, the pre-commit hook, or any other script re-implement the same phase logic? Where would extractions land (one shared `_common.sh` function, or a new `_commit_phases.sh` module)?
   - Agent C: read `commit_enhanced.bats` and any pre-commit hook tests; document the behavioral contract that must survive a refactor.
3. **Phase 2** — Read the critical files yourself (don't delegate understanding). Then 1–2 `Plan` agents with full Phase 1 context: propose interface shape (function names, return semantics, error propagation), exact line ranges to replace, what the deletion test says.
4. **Phase 3** — `AskUserQuestion` for genuinely unresolved choices. Likely: scope of extraction (all phases vs just the duplicated ones), whether to fold in any latent bugs, whether to keep `commit_enhanced.sh` as a thin orchestrator vs split it into orchestrator + phase scripts.
5. **Phase 4** — Overwrite this plan file with the implementation plan for #6 (mirror the structure used for #1, #2, #7).
6. **Phase 5** — `ExitPlanMode`.

### Implementation conventions (re-stated for next session)

- Bash style: `set -uo pipefail`, ShellCheck-clean, `# shellcheck source=` directives.
- Module location: append to `scripts/git/_common.sh` (or create a new `_commit_phases.sh` if Phase 1 says scope warrants it). Update the function index header.
- Tests: unit tests in `tests/unit/common.bats` for pure logic (e.g., commit-message format validation); integration tests in `tests/integration/commit_enhanced.bats` for end-to-end.
- Run all 362 tests after each substantive change. Don't ship if count drops.
- CGW wrappers for git: `./scripts/git/commit_enhanced.sh --skip-lint --staged-only "<msg>"` then `./scripts/git/push_validated.sh --skip-lint`. Stage with explicit file names — never `git add .`.
- Drift smoke (post-implementation): `grep -rn` for any duplicated phase logic that should now route through the new module.

### Follow-up message to paste at the start of the next session

```
Continue the architectural-deepening review of CGW (claude-git-workflow) at
F:\RD_PROJECTS\COMPONENTS\claude-git-workflow. Branch: development; in sync
with origin. 362 bats tests passing.

Three candidates from the architectural review are completed:
  #2 backup-tag registry module      (commit c070a22)
  #1 local-only file matcher         (commit c44a6a0)
  #7 conflict-resolution policy      (commit b05f30e — last session)

The next candidate to work on is #6: commit_enhanced.sh phase extraction.

The tracking plan with status, completed work, and Phase 1 seed for #6 lives
at: docs/architecture-deepening-plan.md (in the project repo).

Start by entering plan mode, then run the Phase 1 exploration described in
that plan ("Where to look first" + "Workflow for the next session" sections).
Don't write any code until I approve via ExitPlanMode.
```
