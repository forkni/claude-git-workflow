## v0.6.0 (2026-07-07)

> Changes since `v0.5.0`

### New Features

  - state-aware menu with repo-scan suggestions in auto-git-workflow command (f343d00)
  - redesign auto-git-workflow-cmd as a git-operations menu (33403d0)
  - add branch_diff, pr_checkout, md_toc scripts (625ac56)
  - non-interactive drop/clear in stash_work.sh (+tests, docs) (a08ffb9)

### Bug Fixes

  - add --version heading override and cumulative --prepend to changelog_generate.sh (f12cb07)
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
  - guard add-then-delete local files in merge (Charlie CI G-follow-up) (a7890eb)
  - neutralize origin/HEAD detection exit code so sourcing survives missing ref (a51776c)
  - remove dead code flagged by shellcheck warnings (aea5bf4)
  - scope commit-gate code quality to staged files; close review gaps (f94a94e)
  - scope markdown-lint, add {files} placeholder, guard local-only files in merge/cherry-pick (31586d9)
  - close Tier-1 safety-layer gaps and align skill with Anthropic guidelines (3411006)
  - use target_branch instead of HEAD in push_validated.sh behind/ahead checks (7bab0b3)
  - replace awk field extraction with parameter expansion in recover.sh (47e14b6)
  - replace sed indentation with printf while-read; drop SC2001 disable comment (fd0b4de)
  - replace unquoted string loops with read -ra arrays to prevent word-split on paths with spaces (5bcc643)
  - changelog body-line noise; write v0.5.0 CHANGELOG.md (1d7a754)

### Internal (CI / tests / lint plumbing)

  - fix bats --jobs race conditions and index-lock isolation in CI (ef7ad3b, 8448101, d1d7115, 03b650c)
  - align CI shellcheck severity with local config; fix clock-skew test for UTC/local mismatch (506a7df, 2e5cad0)
  - default CGW_SOURCE_BRANCH in merge_docs.bats and validate_branches.bats harnesses after main merge (a07126d, 44fbdd3)
  - preserve original bats --jobs directory args when nothing is filtered (8d23f75)

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

  - skip slow common.bats locally in run.sh (CI runs full; CGW_RUN_SLOW=1 overrides) (c1845ae)
  - iteratively expand the auto-git-workflow eval benchmark from 20 to 66 trajectory-scoped cases with step-efficiency checks (e384bd4, 48cc6b7, 4cb008d, c8b20c1, 34df57e)
  - add merge_docs.bats missed from the review-fixes commit (4345b1b)

### Code Style

  - shfmt reformats — multi-line compound commands and alignment (2a8c54b)

### Maintenance

  - upgrade actions/checkout v4 → v7 (node24 runtime) (b3e2cbb)
  - ignore docs/progit.txt, progit.pdf, SHELL_STYLE_GUIDE.md (438462c)

## v0.5.0 (2026-06-01)

> Changes since `v0.4.0`

### New Features

  - cgw-install.cmd — offer to install jq via winget if not found (PI-07) (c782c2c)
  - add signing support, recover.sh, pre-rebase hook, worktree_manage.sh (98387f0)

### Bug Fixes

  - guardrail false positives — strip quoted strings before pattern matching (d4f20ac)
  - configure.sh — add Python fallback for PreToolUse guardrail when jq is not available (70f4c52)
  - cgw-install.cmd — add pre-rebase to PI-04 check, copy step, backup, and summaries; remove hardcoded script count (21364b4)
  - Pro Git audit — worktree-safe rebase detection, NUL conflict paths, exact path matching, changelog separators, bisect ref (e92b00f)

### Documentation

  - update skill, script-reference, usage, configuration, installation for new tools; fix pre-commit CGW_SKIP_TYPECHECK bug (6a2cf34)

## v0.4.0 (2026-05-26)

> Changes since `v0.3.2`

### New Features

  - add cgw_rev_count / cgw_remote_reachable / cgw_remote_branch_exists to _common.sh (393b0b2)
  - auto-detect typechecker in configure.sh (pyrefly-first for Python) (5548fff)
  - add CGW_TYPECHECK_CMD non-blocking typecheck step to pre-commit hook (e150941)

### Bug Fixes

  - preserve empty CGW_TYPECHECK_CHECK_ARGS for pyright (use ${var-default} not ${var:-default}) (eaabf94)

### Documentation

  - improve auto-git-workflow skill — thin runner command, verified harness, sync helper (fa06e8c)

### Tests

  - add skip-guards for jq/typechecker env deps; fix git add -f for global gitignore (b609db0)

## v0.3.2 (2026-05-12)

> Changes since `v0.3.1`

### New Features

  - auto-recover stale .git/index.lock in all mutating scripts (2d12b16)
  - add PreToolUse harness guardrail for defense-in-depth (2594017)
  - add CGW_LOCAL_FILES_EXEMPT to allow specific files through local-only protection (19dc033)

### Bug Fixes

  - drop user-invocable on skill so /auto-git-workflow isn't duplicated (7ef5ea6)
  - allow staged deletions of local-only files to pass through commit and push (66ba523)
  - move Installing X... echo inside install functions so reconfigure shows no-op correctly (963e9ec)
  - export CGW_NON_INTERACTIVE in no-TTY auto-detect so cgw_confirm resolves correctly (828cb6c)
  - cgw_confirm accepts abbreviated y/yes/n/no inputs (case-insensitive) (f654635)
  - source _common.sh in configure.sh so cgw_confirm resolves correctly (bca5c48)
  - lowercase cgw_confirm abort message to match test expectation (fca6d70)
  - prevent MSYS path conversion corrupting PreToolUse guardrail registration (22a4109)
  - strip inline comments after .cgw.conf values in _config.sh (4c1d491)
  - tolerate CRLF .cgw.conf line endings in _config.sh (bb9eb18)

### Documentation

  - broaden skill description and fix slash-command Section B raw-git contradiction (97c2840)
  - pin interactive-confirmation in CONTEXT.md, record #A and #B in deepening plan (fcbdf26)
  - add lint-pipeline and commit-message-format terms to CONTEXT.md, mark #6 done (da51b7b)
  - track architectural-deepening review status and queue candidate #6 (647ac7e)

### Refactoring

  - share repo via setup_file for read-only test files (79309d5)
  - adopt cgw_confirm across 15 scripts (21170db)
  - add cgw_confirm interactive prompt helper (6f0e208)
  - pre-commit hook adopts cgw_run_lint_check (4580afe)
  - extract lint pipeline helpers to _common.sh (fb0e9b0)
  - adopt run_tool_with_logging in commit_enhanced, fix pre-commit CGW_LINT_CMD, fix re-stage drift (5161461)
  - extract cgw_resolve_lint_binary (sub-candidate C) (b268b66)
  - extract cgw_validate_commit_message (sub-candidate B) (79b02c4)
  - centralize conflict-resolution policy in _common.sh (b05f30e)
  - centralize local-only file matching in _common.sh (c44a6a0)
  - extract backup-tag registry module to _common.sh (c070a22)

### Tests

  - lock down behavior gaps for branch-state refactor (#C1+#C2+#C3) (267c0cf)
  - close lint test-coverage gap (auto-fix, format, markdownlint, --no-venv, prefix-strict) (9a96466)

### Maintenance

  - remove old install.cmd (superseded by cgw-install.cmd) (8a8913f)
  - rename install.cmd to cgw-install.cmd for clarity (1029aab)
  - remove clean_pycache.cmd helper script (ae9fbbf)
  - let tests/run.sh accept path arguments for partial runs (d88dc12)
  - enable parallel test runner via xargs -P (5e3fe65)

## v0.3.1 (2026-04-23)

> Changes since `v0.3.0`

### Documentation

  - align documentation with v0.3.0 codebase changes (d2d0cc0)

## v0.3.0 (2026-04-23)

> Changes since `v0.2.1`

### Bug Fixes

  - apply Google Shell Style Guide -- eval, pipe-to-while, STDERR routing, ${var} consistency (d1e120c)
  - respect pre-staged files in non-interactive commit, add --only/--all flags (94f4ea5)

### Documentation

  - document new staging behavior, --only/--all flags, and --no-venv on push_validated (99d6042)
  - add Pro Git book PDF as offline reference (9bb29dd)

### Maintenance

  - add clean_pycache.cmd helper for clearing __pycache__ and Claude temp files (4909314)

## v0.2.1 (2026-04-17)

> Changes since `v0.2.0`

### Bug Fixes

  - expand ${CGW_REMOTE} in dry-run output so preview mirrors real command (5a72686)

## v0.2.0 (2026-04-17)

> Changes since `v0.1.0`

### New Features

  - add --source/--target overrides, CGW_REMOTE, tag-PID, Bash 3.2 fixes, conflict handlers (8fa67f4)

### Documentation

  - align README, docs/, skill/ with CGW_REMOTE, --source/--target overrides, tag-PID naming (2be3840)

## v0.1.0 (2026-04-14)

Initial release.

### New Features

  - improve sync_branches.sh with dry-run, --branch, --prune flags and add integration tests (ff03d2a)
  - add branch_cleanup, changelog_generate, undo_last, pre-push hook (Pro Git audit) (4d32ece)
  - add bisect_helper.sh and rebase_safe.sh (Pro Git Ch3/Ch7) (8a9a4d7)
  - add C/C++ lint detection (clang-tidy, cppcheck, clang-format) to configure.sh (d15e18f)
  - add install.cmd and drop-in installation benchmark (a20e33a)
  - add C/C++ lint detection (clang-tidy, cppcheck, clang-format) to configure.sh (e8be39f)
  - add install.cmd and drop-in installation benchmark (5c5483d)
  - add PR workflow, --skip-lint flags, and ShellCheck compliance (eeb62bc)

### Bug Fixes

  - reconfigure now uses fresh auto-detected branches, not stale .cgw.conf values (90091fb)
  - address Charlie CI review -- echo( for meta-chars, EXIT_CODE across endlocal, configure.sh failure exit, CGW_LINT_EXTENSIONS +x, auto-create local tracking branch (0f85a5a)
  - resolve shellcheck SC2034 and SC2001 warnings in CI (17beee8)
  - harden install.cmd against special-char paths, UNC pushd, self-install, and partial failures (ac6fd2c)
  - use +x pattern for all CGW_LINT/FORMAT vars in _config.sh to respect empty overrides (326dd0c)
  - add Git Bash to PATH in installer and fix configure.sh source-branch detection (6ba9756)
  - replace non-ASCII characters in scripts for Windows shellcheck compatibility (2d6caa2)
  - address all 10 Charlie CI review findings (a793b75)
  - add readline (-e) to free-text read prompts so arrow keys work (a4e114e)
  - configure.sh no longer modifies .gitignore; preserves branch settings on reconfigure (f767ca3)
  - resolve CGW_ALL_PREFIXES unbound variable in configure.sh pre-push hook install (515fee0)
  - add cgw.conf.example to .gitignore during installation (0b80283)
  - skip branch prompts when not reconfiguring, fix summary values, platform-neutral error messages (b821319)
  - normalize y/yes for reconfigure prompt in configure.sh (57d6d54)
  - configure.sh gracefully handles re-run after install cleanup (already-installed hook/skill) (512b2c0)
  - normalize y/yes responses in configure.sh prompts for branches and yes/no questions (32bdf30)
  - use pushd/popd instead of bash cd to avoid MSYS2 path translation failure (f1fe0f3)
  - rewrite install.cmd with goto pattern to avoid CMD if/else fall-through (5355510)
  - install.cmd PI-02 if/else fall-through and PI-03 head command (e531a19)
  - skip branch prompts when not reconfiguring, fix summary values, platform-neutral error messages (07217d3)
  - normalize y/yes for reconfigure prompt in configure.sh (cc39951)
  - configure.sh gracefully handles re-run after install cleanup (already-installed hook/skill) (7a0f2fa)
  - normalize y/yes responses in configure.sh prompts for branches and yes/no questions (e87a306)
  - use pushd/popd instead of bash cd to avoid MSYS2 path translation failure (52961ad)
  - rewrite install.cmd with goto pattern to avoid CMD if/else fall-through (982f3cf)
  - install.cmd PI-02 if/else fall-through and PI-03 head command (09df522)
  - decouple format from lint in commit_enhanced, self-contained config warn (0af3b42)
  - CGW_LINT_CMD empty-string disable, revert hide_gh to safe shim (b232bdf)
  - address Charlie CI round-3 — config regexes, fetch warning, R1 msg, pr_url, CGW_SKIP_LINT, SC2086 (d044fdf)
  - address Charlie CI round-2 review — harden config loader, add fetch, escape sed &, fix mock (b7a525a)
  - address 9 Charlie CI PR #2 review issues (1477381)
  - env vars now take priority over .cgw.conf (save/restore pattern) (1ee06da)
  - correct 5 unit test failures — grep double-output, bats stderr capture, pipe quoting, test repo root (710c442)
  - address Charlie CI feedback — lint flow, blocking, shellcheck compliance (25c510e)
  - escape pipe chars in sed replacement for hook pattern generation (79b8a94)

### Documentation

  - reorganize README into focused docs/, add --global skill install, improve installer UX (dc76f8c)
  - align docs/skill/code — test counts, backup tags, --revert, --include-merges (c56d116)
  - align all documentation and skill with current codebase (25 scripts, pre-push hook) (4a23beb)
  - add release workflow and align documentation to current codebase (6a89404)
  - align all documentation with current codebase state (audit fixes) (717643f)
  - align skill docs with actual script implementations (5c019b6)
  - add release workflow and align documentation to current codebase (e899e30)
  - align all documentation with current codebase state (audit fixes) (dd345db)
  - align skill docs with actual script implementations (f11796e)

### Tests

  - align --reconfigure test with 90091fb fresh-detection behavior (61f6073)
  - add integration tests for 10 previously uncovered scripts; fix branch_cleanup exit code (8433bf3)
  - fix all integration test failures (92/92 passing) (d1262b8)
  - add bats-core testing pipeline for all CGW scripts (a6bda3b)

### Code Style

  - reformat all scripts from tabs to 2-space indent (shfmt -i 2 -ci) (e3fc729)
  - add prompt hint text to configure.sh branch and local-files inputs (4b1381e)
  - apply BATCH_STYLE_GUIDE to install.cmd (rem, quoted sets, exit /b, CRLF) (63caa3f)
  - add prompt hint text to configure.sh branch and local-files inputs (58a6be9)
  - apply BATCH_STYLE_GUIDE to install.cmd (rem, quoted sets, exit /b, CRLF) (03efe00)
  - apply shfmt formatting across all scripts (44b7d1c)

### Maintenance

  - add internal dev files to .gitignore (2d8c4f2)
  - add Charlie CI agent config and GitHub Actions workflows (42c3590)
  - add contributor info (0dfcdfd)
