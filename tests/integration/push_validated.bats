#!/usr/bin/env bats
# tests/integration/push_validated.bats - Integration tests for push_validated.sh
# Runs: bats tests/integration/push_validated.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout development
}

teardown() {
  cleanup_test_repo
}

_run_push() {
  # PATH is already correct from setup_mock_bin; PROJECT_ROOT pins scripts to TEST_REPO_DIR.
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=ruff
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/push_validated.sh' $*
  "
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run exits 0 without pushing" {
  run _run_push "--dry-run --skip-lint"
  [ "${status}" -eq 0 ]
}

@test "--dry-run output mentions dry run" {
  run _run_push "--dry-run --skip-lint"
  [[ "${output}" == *"dry"* ]] || [[ "${output}" == *"DRY"* ]] || [[ "${output}" == *"preview"* ]]
}

@test "--dry-run does not advance remote ref" {
  # Add a commit before dry-run
  echo "new" > "${TEST_REPO_DIR}/new.txt"
  git -C "${TEST_REPO_DIR}" add new.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: new file"
  local before_remote
  before_remote=$(git -C "${TEST_REPO_DIR}" ls-remote origin refs/heads/development | cut -f1)

  _run_push "--dry-run --skip-lint" || true

  local after_remote
  after_remote=$(git -C "${TEST_REPO_DIR}" ls-remote origin refs/heads/development | cut -f1)
  [ "${before_remote}" = "${after_remote}" ]
}

# ── --skip-lint passthrough ───────────────────────────────────────────────────

@test "--skip-lint exits 0 without calling ruff" {
  run _run_push "--skip-lint --dry-run"
  [ "${status}" -eq 0 ]
  # ruff mock log should not exist or be empty
  if [ -f "${MOCK_BIN_DIR}/ruff.log" ]; then
    [ ! -s "${MOCK_BIN_DIR}/ruff.log" ]
  fi
}

# ── --skip-md-lint passthrough ────────────────────────────────────────────────

@test "--skip-md-lint is accepted and exits 0 in dry-run" {
  run _run_push "--skip-lint --skip-md-lint --dry-run"
  [ "${status}" -eq 0 ]
}

@test "--no-venv is accepted and exits 0 in dry-run" {
  run _run_push "--no-venv --skip-lint --dry-run"
  [ "${status}" -eq 0 ]
}

# ── --skip-typecheck passthrough / typecheck gate wiring ──────────────────────

@test "--skip-typecheck is accepted and exits 0 in dry-run" {
  run _run_push "--skip-lint --skip-typecheck --dry-run"
  [ "${status}" -eq 0 ]
}

@test "typecheck-only project (no lint/format/markdown) still runs the pre-push check and blocks on type errors" {
  MOCK_TYPECHECK_EXIT=1 install_mock_typecheck
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/push_validated.sh'
  "
  # Without CGW_TYPECHECK_CMD reaching the ':233' concatenation, the whole
  # pre-push lint block would be skipped (no CGW_LINT_CMD/FORMAT/MARKDOWNLINT)
  # and this push would succeed. It must instead abort on the type error.
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Lint check failed"* ]] || [[ "${output}" == *"Typecheck"* ]]
}

@test "typecheck-only project with --skip-typecheck pushes successfully despite type errors" {
  MOCK_TYPECHECK_EXIT=1 install_mock_typecheck
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_MARKDOWNLINT_CMD=''
    export CGW_TYPECHECK_CMD=mock-typecheck
    export CGW_TYPECHECK_CHECK_ARGS=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/push_validated.sh' --skip-typecheck
  "
  [ "${status}" -eq 0 ]
}

# ── Protected branch force-push protection ────────────────────────────────────

@test "force-push to protected main branch aborts in non-interactive" {
  git -C "${TEST_REPO_DIR}" checkout main
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_PROTECTED_BRANCHES=main
    bash '${CGW_PROJECT_ROOT}/scripts/git/push_validated.sh' --force --skip-lint
  "
  [ "${status}" -ne 0 ]
}

# ── --branch: push a non-checked-out branch ───────────────────────────────────

@test "--branch main from development: no false 'behind' abort and remote advances" {
  # Reproduce the bug precisely: push_validated.sh used HEAD (= development here)
  # instead of target_branch (= main) for the behind-remote check.  The bug fires
  # only when origin/main has commits NOT reachable from HEAD/development, which is
  # realistic in a merge-based workflow where merge commits land on main but not
  # on development.
  #
  # Setup:
  #   1. Push a commit to origin/main via main (origin/main gains commit A).
  #   2. Make another commit on local main (commit B, not yet pushed).
  #   3. Stay on development (which knows nothing of A or B).
  #
  # With the bug: cgw_rev_count HEAD origin/main = 1 (commit A) → "1 behind" → abort.
  # After fix:   cgw_rev_count main origin/main = 0              → no warning → push B.

  # Step 1 – advance origin/main with a commit development never sees.
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  echo "origin-only" >"${TEST_REPO_DIR}/origin_advance.txt"
  git -C "${TEST_REPO_DIR}" add origin_advance.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: advance origin/main only"
  git -C "${TEST_REPO_DIR}" push --quiet origin main   # origin/main now has commit A

  # Step 2 – add another local commit on main that needs pushing (commit B).
  echo "local-ahead" >"${TEST_REPO_DIR}/local_ahead.txt"
  git -C "${TEST_REPO_DIR}" add local_ahead.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: commit to push via --branch flag"
  local expected_sha
  expected_sha=$(git -C "${TEST_REPO_DIR}" rev-parse main)

  # Step 3 – return to development; HEAD now diverges from origin/main.
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  # Sanity: origin/main has 1 commit (A) that development cannot reach.
  local stale_count
  stale_count=$(git -C "${TEST_REPO_DIR}" rev-list --count development..origin/main)
  [ "${stale_count}" -ge 1 ]   # precondition: bug would have triggered here

  local before_remote
  before_remote=$(git -C "${TEST_REPO_DIR}" ls-remote origin refs/heads/main | cut -f1)

  run _run_push "--branch main --skip-lint"

  # Must not abort: fixed code measures main vs origin/main, not HEAD vs origin/main.
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"behind"* ]]

  # origin/main must have advanced to commit B.
  local after_remote
  after_remote=$(git -C "${TEST_REPO_DIR}" ls-remote origin refs/heads/main | cut -f1)
  [ "${after_remote}" = "${expected_sha}" ]
  [ "${before_remote}" != "${after_remote}" ]
}

@test "--branch main from development: ahead count reflects main, not development" {
  # Companion: the "commits to be pushed" display must count main's commits over
  # origin/main, not HEAD/development's divergence from origin/main.
  #
  # Same setup: advance origin/main once (commit A), then add one more local commit
  # on main (commit B).  After fix, "ahead = 1" (only B); before fix it would show
  # the divergence of development from origin/main (which may be 0 or wrong).

  git -C "${TEST_REPO_DIR}" checkout --quiet main
  echo "origin-only-2" >"${TEST_REPO_DIR}/origin_advance2.txt"
  git -C "${TEST_REPO_DIR}" add origin_advance2.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: advance origin/main for ahead-count test"
  git -C "${TEST_REPO_DIR}" push --quiet origin main   # origin/main gains commit A

  echo "local-ahead-2" >"${TEST_REPO_DIR}/local_ahead2.txt"
  git -C "${TEST_REPO_DIR}" add local_ahead2.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: ahead count test commit"
  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run _run_push "--branch main --skip-lint"

  [ "${status}" -eq 0 ]
  # Exactly 1 commit (commit B) is ahead of origin/main on the main branch.
  [[ "${output}" == *"Local ahead of origin/main: 1 commit(s)"* ]]
}

# ── Force-push lease resolution (narrowed fetch refspec) ──────────────────────

@test "force-push succeeds when fetch refspec does not cover the branch" {
  # Narrow origin's fetch refspec to only 'main', simulating a fork/CI clone
  # whose remote.origin.fetch never learns about other branches (repro of the
  # 'stale info' bug: bare --force-with-lease derives its expected value from
  # the local remote-tracking ref, resolved via the configured fetch refspec --
  # it does not query the remote directly).
  git -C "${TEST_REPO_DIR}" config --replace-all remote.origin.fetch \
    "+refs/heads/main:refs/remotes/origin/main"

  git -C "${TEST_REPO_DIR}" checkout --quiet -b feature/x main
  echo "v1" >"${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: v1"
  git -C "${TEST_REPO_DIR}" push --quiet origin feature/x
  # A plain push (no -u/--set-upstream) does not create a local tracking ref,
  # and the narrowed refspec above would not cover it even if fetched --
  # this reproduces "never fetched under a narrowed refspec" exactly.
  git -C "${TEST_REPO_DIR}" update-ref -d refs/remotes/origin/feature/x 2>/dev/null || true

  # Rewrite history (amend) so the push genuinely requires --force.
  echo "v2" >"${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --amend -m "feat: v2 (rewritten)"
  local expected_sha
  expected_sha=$(git -C "${TEST_REPO_DIR}" rev-parse feature/x)

  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run _run_push "--branch feature/x --force --skip-lint"

  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Unknown flag"* ]]

  local after_remote
  after_remote=$(git -C "${TEST_REPO_DIR}" ls-remote origin refs/heads/feature/x | cut -f1)
  [ "${after_remote}" = "${expected_sha}" ]
}

@test "force-push logs an explicit --force-with-lease=<ref>:<sha> matching the pre-push remote tip" {
  # Anti-regression guard: assert the actual git command line, not just the
  # exit code, so this fix can never silently degrade into bare --force (which
  # always "succeeds" but drops the safety check entirely).
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feature/y main
  echo "v1" >"${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: v1"
  git -C "${TEST_REPO_DIR}" push --quiet origin feature/y
  local remote_tip
  remote_tip=$(git -C "${TEST_REPO_DIR}" rev-parse feature/y)

  echo "v2" >"${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --amend -m "feat: v2 (rewritten)"

  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run _run_push "--branch feature/y --force --skip-lint"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--force-with-lease=refs/heads/feature/y:${remote_tip}"* ]]
}

@test "force-push to a branch absent on the remote pushes without a lease" {
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feature/new development

  run _run_push "--branch feature/new --force --skip-lint"

  [ "${status}" -eq 0 ]
  [[ "${output}" != *"force-with-lease="* ]]
  local after_remote
  after_remote=$(git -C "${TEST_REPO_DIR}" ls-remote origin refs/heads/feature/new | cut -f1)
  local expected_sha
  expected_sha=$(git -C "${TEST_REPO_DIR}" rev-parse feature/new)
  [ "${after_remote}" = "${expected_sha}" ]
}

@test "force-push after rebase (behind > 0) does not require confirmation" {
  # A rev-count "behind" is expected after any rewrite -- it must not gate
  # --force, or every legitimate rebase-then-force-push (rebase_safe.sh's
  # documented flow) would abort non-interactively.
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feature/z main
  echo "v1" >"${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: v1"
  git -C "${TEST_REPO_DIR}" push --quiet origin feature/z

  echo "v2" >"${TEST_REPO_DIR}/feature.txt"
  git -C "${TEST_REPO_DIR}" add feature.txt
  git -C "${TEST_REPO_DIR}" commit --quiet --amend -m "feat: v2 (rewritten)"

  git -C "${TEST_REPO_DIR}" checkout --quiet development

  run _run_push "--branch feature/z --force --skip-lint"

  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Continue push anyway?"* ]]
}

@test "force-push to source branch (development) blocked in non-interactive" {
  # bug: push_validated.sh only checks CGW_PROTECTED_BRANCHES (default=main);
  # CGW_SOURCE_BRANCH (development) is not included so --force proceeds silently.
  # Fixed by cgw_is_protected_branch which uses the canonical set
  # (CGW_TARGET ∪ CGW_SOURCE ∪ CGW_PROTECTED_BRANCHES).
  skip "bug #C3: push_validated.sh does not protect CGW_SOURCE_BRANCH -- unskip after protected-branch refactor"
  # development is the current branch (from setup) with a local remote.
  # CGW_PROTECTED_BRANCHES is left at its default (=main).
  # Force-pushing to development should be blocked because it is CGW_SOURCE_BRANCH.
  run _run_push "--force --dry-run --skip-lint"
  [ "${status}" -ne 0 ]
}
