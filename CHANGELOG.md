# Changelog

## v0.11.1 (2026-10-05)

> Changes since `v0.11.0`

### Behaviour changes

- **Guardrail: quoting a command word no longer hides it.** `cgw_guardrail_classify` used to delete every quoted span before matching, so `git "push" --force` or `git 'commit' -m x` slipped past the agent guardrail while the shell ran them unquoted. Quotes are now stripped but their content is kept as one token: a quoted single word matches like its unquoted form, while a quoted sentence (a commit message, PR title, `echo`/`grep` argument, even one containing `;`/`|`/`&` or newlines) stays a single non-matching token. The classifier still never identifies the executable, so `echo git commit` is redirected quoted or not, the same way `env git commit` is caught.
- **`check_lint.sh --ref` exits `3` when the snapshot cannot be prepared** (unresolvable `--ref`/`--base`, pushed-file discovery, temp dir, extract, cd). Previously these exited `1`, which `push_validated.sh` treated as an overridable lint failure. `3` means the checks did not run: `push_validated.sh --pushed-only` now stops with "Could not check the pushed snapshot" and never offers the "push anyway" prompt. `--worktree` or `--skip-lint` remain the explicit bypasses. Exit codes: `0` ok, `1` lint/markdown, `2` typecheck, `3` setup failure.

### Bug Fixes

- **Editable installs no longer leak the working tree into the snapshot typecheck.** Cause: a src-layout editable install leaves a venv `.pth` pointing at `<project>/src`, so a committed file importing an uncommitted module (a forgotten `git add new.py`) resolved to the working-tree copy and mypy, pyright and pyrefly all passed on code CI rejects. `--ref` runs now put a `sitecustomize` on `PYTHONPATH` (chained to any existing one, kept outside the snapshot) that drops `sys.path` entries under the project root, except the snapshot and the interpreter prefixes, and setuptools `__editable__` finders. See `docs/KNOWN_ISSUES.md` for the remaining limits (`tsc`, clang-tidy).
- **`--base` resolves through `refs/remotes/<remote>/<branch>`** so a local branch or tag named like the remote branch cannot shadow it.
- **Non-ASCII file names are kept** when discovering pushed files (`core.quotePath=false`).
- **Markdown scope in `--ref` mode follows `CGW_MARKDOWNLINT_PATHS`** (`:(glob)` pathspecs, root-level files included) and only `.md`/`.markdown` files reach markdownlint.
- `get_python_path` honours `CGW_VENV_ROOT`, so snapshot runs use the project's `.venv`.
- **Guardrail dequoting follows shell backslash escapes.** A quoted message with escaped inner quotes (`commit_enhanced.sh "say \"git commit is\" dangerous"`) was split at the first `\"` and blocked as `git commit`. Outside quotes and inside `"..."` a backslash pair is now content, so `\"` neither opens nor closes a span; inside `'...'` a backslash stays literal and the first `'` closes.

### Documentation

- `README.md` and `docs/` realigned with the scripts and CI: `--pushed-only` gate and exit codes, `branch_cleanup.sh`/`clean_build.sh` flags, `tests/run.sh` modes, guardrail behaviour, installer names and uninstall steps, and refreshed `KNOWN_ISSUES.md`.

## v0.11.0 (2026-10-04)

> Changes since `v0.10.0`

### New Features

- **Pushed-only gate scope for lint and typecheck:** `push_validated.sh` now supports `--pushed-only` (and `CGW_PUSH_LINT_SCOPE=pushed`) to validate the committed snapshot of the branch being pushed instead of the working tree, allowing pushes to succeed even when unrelated uncommitted work is in progress. `--worktree` forces working-tree scope for a single run.

### Bug Fixes

- **Preserve configured lint and format excludes in file-scoped checks:** `cgw_run_lint_check`, `cgw_run_format_check`, and `cgw_run_lint_fix` now retain `CGW_LINT_EXCLUDES` and `CGW_FORMAT_EXCLUDES` when invoked with an explicit file list (such as in snapshot mode or staged-only commits), preventing excluded paths from blocking validation.
- **Include merge diffs in unpushed file discovery:** `cgw_pushed_files_for_lint` now includes `-m` when scanning unpushed commits (`--not --remotes`), ensuring files modified or resolved in unpushed merge commits are discovered and validated.
- **Fail closed on pushed-file discovery failure:** `check_lint.sh` now verifies the exit status of `cgw_pushed_files_for_lint` and aborts if file discovery fails, rather than silently continuing with an empty scope.
- **Harden snapshot cleanup on Windows:** `check_lint.sh` changes directory out of the temporary snapshot folder before deletion to prevent `rm -rf` access-denied failures on Windows.
- **Protect branch ref resolution against tag shadowing:** `push_validated.sh` now resolves target refs with `refs/heads/` to prevent same-named tags from shadowing branches.

## v0.10.0 (2026-10-03)

> Changes since `v0.9.0`

### Behaviour changes

- **Modify/delete (`DU`) conflicts now halt** in `merge_with_validation.sh`, `cherry_pick_commits.sh` and every other caller of `cgw_resolve_safe_conflicts`, instead of silently `git rm`-ing the file and dropping the other side's changes. The message lists the files and the two choices (`git rm <file>` / `git add <file>`). Set `CGW_AUTO_RESOLVE_MODIFY_DELETE=1` to restore auto-removal for text files; binary files (gitattributes `binary`/`-diff`, or a NUL byte) always halt. Both-deleted (`DD`) is still auto-resolved. See `docs/adr/0005-modify-delete-conflicts-halt.md`.

- **Outdated stock hooks are refreshed on update.** `configure.sh` (and so `cgw-install.cmd` / `cgw-batch-install.cmd`) now replaces an installed `.githooks/pre-commit|pre-push|pre-rebase` that is an unmodified older CGW version, instead of keeping every differing hook as a "locally established" one — which left consumer projects frozen on old hooks and missing later fixes. A hook that matches no CGW version is still kept. No `.bak` is written for a refresh (the old version is in CGW git; the message names the commit). See `docs/adr/0006-refresh-stale-stock-hooks.md`.

- **`worktree_manage.sh link` no longer creates symlinks/junctions.** It writes a real `scripts/git/` directory of shims (marker `.cgw-worktree-shims`) that exec the main worktree's scripts, and no longer links `.githooks` (hooks and `install_hooks.sh` already fall back to the main worktree). Re-running `link` replaces a legacy link. Cause of the change: on Windows, a raw `git worktree remove` follows an NTFS junction and empties the **main** checkout's gitignored `scripts/git` and `.githooks`; only `worktree_manage.sh remove` unlinked first. With no link, any removal method is harmless. The agent guardrail now also blocks raw `git worktree remove` (including `git -C <path> worktree remove`) and points to `worktree_manage.sh remove --execute`.

### New Features

- `tests/run.sh --help` / `--version`; unknown `--` options are now rejected (exit 2) instead of being passed to `find`/`bats` as paths.
- `cgw-batch-install.cmd` now prints `configure.sh` warnings (e.g. a customised hook it kept) under the project, marks it `Updated (with warnings)`, and adds a `Warnings:` count and list to the summary; exit code is unchanged. Previously the log holding them was deleted on success. The batch no longer pre-copies `.githooks/*.bak` itself.
- `merge_pr.sh <N>`: merges a GitHub PR with a merge commit (`gh pr merge --merge`, explicit `--repo`), refuses a non-OPEN PR, and prints the merge SHA with the `rollback_merge.sh --revert` hint. `--retarget <M>` (repeatable) moves stacked PRs onto the merged PR's base after the merge, `--delete-branch` removes the head branch last, `--dry-run` previews. `--squash`/`--rebase` need `--allow-non-merge` in non-interactive mode and warn that the PR can't be reverted as one unit. Before merging it tags the base branch's remote tip as `pre-merge-*` (the merge commit's first parent, so `rollback_merge.sh`'s `HEAD^1` guard accepts it); `--delete-branch` deletes in the PR's head repository (not the base repo, for cross-repository PRs) and the script exits non-zero if that deletion fails. If the PR is still not `MERGED` after `gh pr merge` (merge queue / auto-merge), it reports that and skips `--retarget`/`--delete-branch`. It now refuses to merge unless the base fetch and the `pre-merge` tag (verified to point at the fetched tip) both succeed, and unless the PR's checks are green (`gh pr checks`): pending checks refuse unless `--wait-checks` (`--watch --fail-fast`), failing checks always refuse, and `--skip-checks` bypasses the gate with a warning.
- `rebase_safe.sh --onto <newbase> --upstream <ref>`: git's three-argument `rebase --onto <newbase> <upstream>`, replaying only `<upstream>..HEAD`.
- `worktree_manage.sh add <path> [<branch> [<base>]]` / `--base <ref>`: create the new branch from a base ref instead of HEAD.
- `create_release.sh --allow-non-semver`: tag with any valid ref name (archive/snapshot tags); no `v` prefix is added and the output notes that `release.yml` fires only on `v*`.
- `configure.sh --hooks-only`: refresh only the git hooks (with `--overwrite-hooks` / `--template-dir`) without touching `.cgw.conf`, the skill, command or guardrails.
- `CGW_AUTO_RESOLVE_MODIFY_DELETE` config key (default `0`); `configure.sh` writes it to `.cgw.conf` as a commented opt-in.

### Bug Fixes

- An `index.lock` collision that outlasted `CGW_LOCK_RETRY_ATTEMPTS` returned git's raw `128` from `run_git_with_logging` / `cgw_run_with_lock_retry`, which `merge_with_validation.sh` and the other callers read as "git ran and hit conflicts" — so a merge that never happened could end in `[OK] MERGE SUCCESSFUL`. Both helpers now return `CGW_RC_INDEX_LOCKED` (75) once retries are exhausted. `CGW_LOCK_RETRY_ATTEMPTS=0` (or a non-numeric value) is treated as 1 instead of silently skipping the command.
- `cherry_pick_commits.sh`: when a conflict needs manual resolution (e.g. modify/delete), the EXIT trap aborted the paused pick and switched back to the original branch, so the printed `git add` / `git cherry-pick --continue` steps could not be followed. The pick now stays paused on the target branch.
- A stock-hook refresh in `configure.sh` also refreshes the matching active `.git/hooks/<hook>`, so the follow-up `install_hooks.sh` no longer leaves a `.bak` (ADR 0006). `CGW_TEST_TIMINGS=1 tests/run.sh` now reports timings on machines with `flock` too (it uses the per-file path instead of native `bats --jobs`).
- `stash_work.sh pop` reported an index-lock refusal as "conflicts may need manual resolution" and advised `git stash drop`, although nothing had been applied — following it would delete the only copy of the work. A lock refusal now says the stash was not applied and is still saved.
- Docs: `sync_branches.sh` on protected branches is `--ff-only` and `rollback_merge.sh --non-interactive` only auto-picks a `pre-merge` tag equal to `HEAD^1`; README and `docs/usage.md` described the old rebase / "latest backup" behaviour.
- `rebase_safe.sh` counted *unpushed* commits as "already pushed" (`origin/<br>..HEAD`), so the published-history warning fired for local-only work and stayed silent for pushed commits. It now counts commits reachable from `${CGW_REMOTE}/*`, matching `hooks/pre-rebase`; `--squash-last` uses the same count.
- `worktree_manage.sh add` exited 1 after a successful add.

## v0.9.0 (2026-10-01)

> Changes since `v0.8.0`

### Behaviour changes

- `cherry_pick_commits.sh` records the source commit (`cherry-pick -x`, also on `--only` partial picks); opt out with `--no-x`.
- `rollback_merge.sh` separates the reset point (hard mode) from the merge under revert (`--revert`); `--revert` never reverts `HEAD~1` or a tag, hard mode only auto-picks a `pre-merge` tag that is `HEAD^1`, and a revert prints the revert-the-revert step.
- `sync_branches.sh` pulls protected branches `--ff-only` (diverged = refuse + reconcile options) and others `--rebase=merges`.
- `push_validated.sh` adds `--set-upstream` only when the branch has no upstream.

### Bug Fixes

- default ruff args include `--force-exclude` (A4)
- check restore/rollback/checkout results instead of reporting false success (sync, merge, cherry-pick)
- `bisect_helper.sh --run` no longer word-splits quoted arguments
- `commit_enhanced.sh --only` clears pre-staged files on an unborn HEAD
- error output goes to stderr in hooks, `_common.sh` and `branch_cleanup.sh`
- `configure.sh` honours env-only `CGW_NON_INTERACTIVE` (a differing hook is kept, not aborted) and warns when a preserved hook differs from the template, pointing at `--overwrite-hooks` and `.githooks/<hook>.local`
- `configure.sh` / `install_hooks.sh` never overwrite an existing `.bak` (timestamped `.bak.<ts>-<pid>` instead, via `cgw_backup_file`)
- `hooks/pre-push` runs the local test gate only for branch updates (not tag pushes or deletions) and honours `SKIP_TESTS=1`
- `cgw_run_with_lock_retry` streams stderr live; redundant mid-script lock checks removed
- an `index.lock` refusal is no longer misread as a git failure: `run_git_with_logging` / `cgw_run_with_lock_retry` return `CGW_RC_INDEX_LOCKED` (75) when git never ran, and merge, cherry-pick (incl. `--only`) and rebase (`--onto`, squash, `--continue`, `--skip`) stop on it instead of reporting conflicts / "already applied" / "MERGE SUCCESSFUL", running `reset --hard`, or orphaning the rebase auto-stash
- `ensure_no_stale_index_lock` waits out a *fresh* lock even while a merge/rebase/cherry-pick/bisect is in progress (a transient IDE lock no longer breaks `--continue`/merge commits); the in-progress refusal applies only to a stale lock
- `bisect_helper.sh --run` launches the command with the running bash (`${BASH}`), not whatever `bash` is first on `PATH`

### Maintenance

- shellcheck and shfmt clean across `scripts/` and `hooks/`; CI shfmt/shellcheck cover `hooks/`

## v0.8.0 (2026-09-29)

> Changes since `v0.7.0`

### New Features

- decouple template sourcing from target repository roots (4a66634)
- add Antigravity Agents integration and guardrail (71d1296)
- add CGW_FREEFORM_MESSAGE_BRANCHES for upstream PR branch exemption (89a1fd7)
- add automated markdown lint auto-fixing to CGW toolkit (e002340)
- add mandatory CI verification gate to every push (b6e63c0)
- enforce Pro Git 50/72 commit subject-length rule (30cf0eb)
- add cgw-batch-install.cmd to refresh CGW toolkit across multiple projects (c291543)
- fail commit when staged blob diverges from validated working tree (#10) (1d25367)
- fail commit when staged blob diverges from validated working tree (55011a5)

### Bug Fixes

- fail closed on deleted diff-blind files in clean tree scan
- probe node capability for markdownlint detection (131dbe2)
- resolve known issues C1, E1, Obs 1-8 with integration tests (ace6153)
- guard rollback_merge root revert and recover reflog pipefail (e6ceb40)
- accept documented --dry-run in branch_cleanup.sh and clean_build.sh (79f3f81)
- fail closed on partial stages during auto-fix re-stage (1a89f0b)
- use git config for merge conflict style instead of invalid merge flag (5927c58)
- disable markdownlint npx fallback by default in test mocks (b29110a)
- re-verify markdown lint after interactive auto-fix (f9f234e)
- pin CGW_MARKDOWNLINT_CMD in fix_lint.bats to avoid CI-only npx fallback (61fe1ea)
- correct fast-forward claim in CI-gate docs (07a5a6d)
- suppress phantom CRLF divergence in commit guard (bf952c5)
- exclude already-pushed commits in pre-push (39017cb)
- strip commit prefix on bare colon, not colon+space (e9b5e11)
- validate subject-length config as integers (1523c22)
- preserve pre-existing hooks/skill/command dirs in batch install (cc7b50f)
- measure subject line only in commit-length check (fa41e9e)
- conclude merge commits when resolved tree matches HEAD (cb18356)
- fail closed when staged file is missing or unhashable during divergence check (3c39cf3)

### Documentation

- fix MD032 list formatting in CONTEXT.md and ADR 0002 (009c99d)
- reconcile commit-message policy with freeform-branch exemption (b8cb943)
- add ADR 0001 for partial-staging fail-closed decision (63753af)
- fix markdown lint errors (fenced-code-language, emphasis-as-heading) (b99eae4)
- document merge as a valid CGW_MERGE_CONFLICT_STYLE value (a60c264)
- fix markdownlint MD040/MD041 violations flagged by docs-validation CI (17d25d3)
- add ci-verification.md reference doc (5ad04fc)

### Refactoring

- own lint plan and unify preconditions (7e735c0)

### Code Style

- remove trailing blank lines at EOF (3cf9da2)
- apply shfmt formatting to _common.sh and_config.sh (9266437)

### Maintenance

- remove stale docs/STYLE_AUDIT.md and docs/architecture-deepening-plan.md (93b08f0)

### Other Changes

- fix(commit): make --interactive fully interactive; test prompts through it (8bf3c96)
- refactor(configure): drive harness skill installs and prompts from one spec (f74d22b)
- fix(merge): stay on the target branch after a successful merge (afdc02e)
- fix(hooks): honour CGW_SKIP_LINT=1 for every pre-commit check (c612115)
- feat(lint): check and fix a format-only config in every lint entry point (43700ef)
- refactor(lint): run check_lint.sh --modified-only through the lint pipeline (2443541)
- feat(config): validate 0/1 switches and enum settings like integers (649e838)
- refactor(config): define every CGW_* setting once in a config registry (09a3bfe)
- docs(config): bring the options table and cgw.conf.example in line (e8a5f48)
- chore(hooks): stop tracking the generated .githooks/ copies (158f969)
- refactor(commit): pull auto-fix, congruence guard and staging mode out of main() (f5f525d)
- test(commit): pin every interactive auto-fix answer through a pty (cf60f33)
- refactor(configure): register every harness guardrail through one spec-driven registrar (d7bba53)
- feat(configure): merge the Antigravity guardrail entry instead of overwriting its key (bc21fa5)
- fix(configure): judge Antigravity no-jq registration per entry (e63c030)
- refactor(guardrail): share one classifier between the cc and agy guardrails (f4918e0)
- test(guardrail): pin both guardrails to one verdict table across payload shapes (fd4948f)
- fix(install): copy the Antigravity .cmd hook runner into target projects (204ddf6)
- fix(rebase): print a restore command that restores the branch (ca8b976)
- fix(configure): close two guardrail install gaps (ab3a5e9)
- fix(lint): resolve CGW_FORMAT_CMD through the venv in --modified-only (1f99d1d)
- fix(commit): re-check lint after an interactive auto-fix (70ea647)
- feat(agy): add Antigravity guardrail hook runner and skill command integration (73926d8)
- fix(configure): fail loudly when the guardrail jq merge cannot write (eb962ad)
- fix(configure): JSON-escape hook commands on the no-jq write path (85309b2)
- fix(hooks): restore stdin read in cc-block-dangerous-git.sh guardrail (010432a)
- fix(install): resolve bash.exe from PATH, never a project-local bash.cmd (5586a91)
- fix(push): keep a force-with-lease guard on new branches and failed probes (75f67f9)
- fix(create-pr): fail closed on unresolvable origin owner/repo (a9cfd9c)
- fix(branch-cleanup): always protect main/master, remote default and worktree branches (254b9e7)
- fix(merge-conclusion): let commit_enhanced.sh finish a hand-resolved merge (dfde977)
- fix(typecheck-gate): make typecheck failures fatal at push, not bypassable (31c5346)
- feat!: block push on failing typecheck (was hook-only advisory) (1510b0a)
- fix(tests): stop CGW_SOURCE_BRANCH tests depending on ambient .cgw.conf (cc4b344)
- fix(freeform): never exempt source, target, or protected branches (dc3cc0d)
- fix(pre-push): stop two freeform-branch exemption leaks (212fe07)
- fix(create-pr): pass explicit --repo to avoid fork/upstream mistarget (d0e87b3)
- fix(push): use explicit --force-with-lease instead of bare form (b0596e1)
- docs(skill): correct check-ignore, hook, and reconfigure claims (2b7c18c)
- docs(skill): add gitignore-templates reference content (40bebc6)
- docs(skill): add gitignore-templates reference doc (dbc0336)
- fix(configure): fail closed on backup failure, harden .gitignore append (5425ae8)
- fix(configure): back up .cgw.conf on --reconfigure and clarify overwrite prompt (aae464c)
- docs(uninstall): warn about junction recursion in linked worktrees (a452a79)
- docs(worktree): fix unreachable link recovery command (8eac220)
- fix(worktree): validate link targets, allow real dirs on remove (c3ed2e9)
- fix(hooks): support git 2.0-2.4 without --git-common-dir (22554f3)
- fix(worktree): fail closed on unresolvable link/remove paths (f21785d)
- fix(hooks): correct install_hooks --help text for worktree-safe hook path (5536c36)
- fix(hooks): scope guardrail checks to one shell invocation (ab4619a)
- feat(worktree): make CGW tooling reachable from linked git worktrees (710fe3c)
- fix(hooks): fail closed when CGW tooling is unreachable (37fd592)
- fix(commit): validated-set guard blind to --skip-md-lint and no-linter case (bb9b241)
- Install pr-review daemon (2873cb4)
- fix(templates): include new markdownlint-cli2.jsonc files in prior commit (18601a5)
- feat(markdownlint): expand rule baseline, add gitignore-aware tool config (73d6016)
- fix(scripts/git): forward fix_lint.sh flags to its check_lint.sh verification (bb37e4d)
- feat(cherry-pick): add --only partial-pick support (9c5af04)
- docs(skill): add wrapper flag reference and conflict rules (b8f3237)
- feat(configure): annotate conf options, add CGW_MERGE_MODE (c3b5dda)
- fix(scripts/git): invoke check_lint.sh via bash to survive non-executable git mode (4db6937)
- fix(scripts/git): close top wrapper gaps from round-1 report (7871ef6)

## v0.7.0 (2026-07-09)

> Changes since `v0.6.0`

### New Features

- protect diverged skip-worktree local files across branch sync (69dcb1d)

### Documentation

- document skip-worktree sync protection in README, usage.md, configuration.md (76c9677)
- bring README up to date with v0.6.0 script additions and integration details (16a5f19)

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

- add cgw_rev_count / cgw_remote_reachable / cgw_remote_branch_exists to_common.sh (393b0b2)
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

- add clean_pycache.cmd helper for clearing `__pycache__` and Claude temp files (4909314)

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
- use +x pattern for all CGW_LINT/FORMAT vars in_config.sh to respect empty overrides (326dd0c)
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
