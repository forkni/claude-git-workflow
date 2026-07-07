## a41cc79 (2026-07-07)

> Changes since `v0.5.0`

### New Features

  - state-aware menu with repo-scan suggestions in auto-git-workflow command (f343d00)
  - redesign auto-git-workflow-cmd as a git-operations menu (33403d0)
  - add branch_diff, pr_checkout, md_toc scripts (625ac56)
  - non-interactive drop/clear in stash_work.sh (+tests, docs) (a08ffb9)

### Bug Fixes

  - address Copilot review — quote scan refs, suppress rev-parse stderr, widen doc-verifier script pattern (906eaad)
  - align configure.sh root detection with _config.sh (cwd-first discovery) (8bc6605)
  - resolve PROJECT_ROOT via git discovery from cwd, not script location (31a2edc)
  - pin PROJECT_ROOT to scratch repo in verify_skill_commands dry-runs (4b74e82)
  - block git rm -f/--force in dangerous-git guardrail (822c556)
  - scope pre-commit hook lint to CGW_LINT_EXTENSIONS (skip non-Python staged files) (ca9576d)
  - add missing auto-git-workflow-cmd.md (menu redesign file was never staged) (dfd6c44)
  - hide auto-git-workflow skill from slash menu (user-invocable: false) (4b8bbcb)
  - surface git's error text when --only staging genuinely fails (8e6ef76)
  - make check_lint.sh --modified-only format check non-blocking (1ea22cd)
  - scope --only force-add to concrete tracked paths, not the whole pathspec (d0c56b9)
  - force-add tracked paths in commit_enhanced.sh --only and test seed helpers (1a9f1d8)
  - label non-blocking FORMAT CHECK section as WARN, not FAILED (bcca374)
  - make local format check non-blocking, matching CI's shfmt policy (ff3d80b)
  - default CGW_SOURCE_BRANCH in merge_docs.bats harness after main merge (a07126d)
  - preserve original bats --jobs directory args when nothing is filtered (8d23f75)
  - guard add-then-delete local files in merge (Charlie CI G-follow-up) (a7890eb)
  - neutralize origin/HEAD detection exit code so sourcing survives missing ref (a51776c)
  - default CGW_SOURCE_BRANCH in validate_branches.bats harness (44fbdd3)
  - remove dead code flagged by shellcheck warnings (aea5bf4)
  - scope commit-gate code quality to staged files; close review gaps (f94a94e)
  - scope markdown-lint, add {files} placeholder, guard local-only files in merge/cherry-pick (31586d9)
  - close Tier-1 safety-layer gaps and align skill with Anthropic guidelines (3411006)
  - serialize common.bats to stop bats --jobs index.lock race on CI (ef7ad3b)
  - isolate test-29 lock from parallel setup() cleanup (bats --jobs race) (8448101)
  - resolve 4 pre-existing CI test failures (index-lock, skip, lint-warn) (d1d7115)
  - array default expansion in run.sh caused bats to receive space-joined paths (03b650c)
  - align CI shellcheck severity with local config (add --severity=error) (506a7df)
  - use touch -d for future mtime in clock-skew test to avoid UTC/local mismatch (2e5cad0)
  - use target_branch instead of HEAD in push_validated.sh behind/ahead checks (7bab0b3)
  - replace awk field extraction with parameter expansion in recover.sh (47e14b6)
  - replace sed indentation with printf while-read; drop SC2001 disable comment (fd0b4de)
  - replace unquoted string loops with read -ra arrays to prevent word-split on paths with spaces (5bcc643)
  - changelog body-line noise; write v0.5.0 CHANGELOG.md (1d7a754)

### Documentation

  - add git-recipes and document new scripts (e9e9431)
  - add conflict-investigation, merge-conclusion, and published-rebase guidance to skill (fc76e16)
  - add resolving-merge-conflicts reference to skill (0dfa959)
  - name pyrefly as the configured Python typechecker default in SKILL.md (0cdad9c)
  - verify and improve auto-git-workflow skill accuracy (a5143dc)
  - add Globals/Arguments/Returns headers to undocumented functions (4364371)
  - update README — add recover.sh, worktree_manage.sh, check_local_files.sh; fix install, hooks, config table (6245161)

### Refactoring

  - auto-detect target branch at runtime, make source explicit (fb5233f)

### Tests

  - revert temporary debug instrumentation from diagnostic commit (2aea517)
  - add temporary debug output to diagnose CI-only merge_docs failure (76a0074)
  - skip slow common.bats locally in run.sh (CI runs full; CGW_RUN_SLOW=1 overrides) (c1845ae)
  - add step-efficiency axis and read-only inspection cases to benchmark (v1.2) (34df57e)
  - expand benchmark 20->40 cases and fix skill's redundant verification behavior (c8b20c1)
  - sync benchmark to v1.1 (66 cases, trajectory-scoped checks) (4cb008d)
  - scope must_not_include checks to trajectory (48cc6b7)
  - add merge_docs.bats missed from the review-fixes commit (4345b1b)
  - add auto-git-workflow eval benchmark (20 cases) (e384bd4)

### Code Style

  - shfmt reformats — multi-line compound commands and alignment (2a8c54b)

### Maintenance

  - upgrade actions/checkout v4 → v7 (node24 runtime) (b3e2cbb)
  - ignore docs/progit.txt, progit.pdf, SHELL_STYLE_GUIDE.md (438462c)


