#!/usr/bin/env bats
# tests/integration/lock_refusal.bats - an index.lock refusal must surface as a lock
# refusal, never be misread as "git ran and hit conflicts".
# Runs: bats tests/integration/lock_refusal.bats
#
# Trigger: a reference-transaction hook drops a stale (back-dated) .git/index.lock the
# moment the pre-<op> backup tag is written. Every script creates that tag right before
# its mutating git call, so the lock appears after the startup check and before the
# operation -- the IDE-grabs-the-lock case. CGW_AUTO_REMOVE_INDEX_LOCK=0 makes the
# refusal immediate (no wait, no removal).

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  install_mock_lint
  _install_lock_hook
}

teardown() {
  cleanup_test_repo
}

_install_lock_hook() {
  local hook="${TEST_REPO_DIR}/.git/hooks/reference-transaction"
  cat >"${hook}" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "committed" ]] || exit 0
if grep -q 'refs/tags/pre-' ; then
  lock="$(git rev-parse --absolute-git-dir)/index.lock"
  : >"${lock}"
  touch -d "120 seconds ago" "${lock}"
fi
exit 0
EOF
  chmod +x "${hook}"
}

_run_cgw() {
  local script="$1"
  shift
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_SOURCE_BRANCH='development'
    export CGW_LINT_CMD='' CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_AUTO_REMOVE_INDEX_LOCK=0
    bash '${CGW_PROJECT_ROOT}/scripts/git/${script}' $*
  " 2>&1
}

@test "merge: lock refusal exits 1, no false success, target untouched" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse main)

  run _run_cgw merge_with_validation.sh --non-interactive
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"[cgw-lock]"* ]]
  [[ "${output}" != *"MERGE SUCCESSFUL"* ]]
  [[ "${output}" != *"conflicts detected"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse main)" = "${before}" ]
}

@test "rebase --onto: lock refusal is not reported as conflicts and the autostash is not lost" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  # Make development's commit local-only: a pushed commit would (correctly) stop at the
  # published-history prompt before the rebase -- and the lock path -- is ever reached.
  git -C "${TEST_REPO_DIR}" update-ref -d refs/remotes/origin/development
  echo "wip content" >>"${TEST_REPO_DIR}/DEV.md"

  run _run_cgw rebase_safe.sh --onto main --autostash --non-interactive
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"[cgw-lock]"* ]]
  [[ "${output}" != *"HIT CONFLICTS"* ]]

  # git stash pop needs the (still stale-locked) index too, so the stash is kept and the
  # user is told how to restore it -- never silently orphaned behind a "conflicts" message.
  [[ "${output}" == *"git stash pop"* ]]
  rm -f "${TEST_REPO_DIR}/.git/index.lock"
  git -C "${TEST_REPO_DIR}" stash pop
  grep -q "wip content" "${TEST_REPO_DIR}/DEV.md"
}

@test "cherry-pick: lock refusal is not reported as conflicts or already-applied" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  local dev_commit
  dev_commit=$(git -C "${TEST_REPO_DIR}" rev-parse development)

  run _run_cgw cherry_pick_commits.sh --commit "${dev_commit}" --target main --non-interactive
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"[cgw-lock]"* ]]
  [[ "${output}" != *"already applied"* ]]
  [[ "${output}" != *"conflicts detected"* ]]
}

@test "cherry-pick --only: lock refusal is not reported as a conflict" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  local dev_commit
  dev_commit=$(git -C "${TEST_REPO_DIR}" rev-parse development)

  run _run_cgw cherry_pick_commits.sh --commit "${dev_commit}" --target main --only DEV.md --non-interactive
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"[cgw-lock]"* ]]
  [[ "${output}" != *"hit conflicts"* ]]
}
