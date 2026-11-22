#!/usr/bin/env bats
# tests/integration/branch_switch.bats - Integration tests for branch_switch.sh
# Runs: bats tests/integration/branch_switch.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  # Tracked file used for the dirty-tree scenarios (stands in for a binary .toe file).
  echo "v1" >"${TEST_REPO_DIR}/work.txt"
  git -C "${TEST_REPO_DIR}" add work.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add work file"
}

teardown() {
  cleanup_test_repo
}

_run_branch_switch() {
  (
    cd "${TEST_REPO_DIR}" || exit 1
    export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
    export PROJECT_ROOT="${TEST_REPO_DIR}"
    export CGW_NON_INTERACTIVE=1
    bash "${CGW_PROJECT_ROOT}/scripts/git/branch_switch.sh" "$@"
  ) 2>&1
}

_current_branch() {
  git -C "${TEST_REPO_DIR}" symbolic-ref -q --short HEAD
}

# ── Argument handling ─────────────────────────────────────────────────────────

@test "no branch name exits 1" {
  run _run_branch_switch
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Branch name required"* ]]
}

@test "unknown flag exits 1" {
  run _run_branch_switch --foobar
  [ "${status}" -eq 1 ]
}

@test "a base ref without -c exits 1" {
  run _run_branch_switch development main
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"only applies to a new branch"* ]]
}

# ── Create ────────────────────────────────────────────────────────────────────

@test "-c creates the branch from HEAD without an upstream" {
  run _run_branch_switch -c feat/new-thing
  [ "${status}" -eq 0 ]
  [ "$(_current_branch)" = "feat/new-thing" ]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "$(git -C "${TEST_REPO_DIR}" rev-parse main)" ]
  run git -C "${TEST_REPO_DIR}" config --get branch.feat/new-thing.merge
  [ "${status}" -ne 0 ]
}

@test "-c with a base starts at the base and sets no upstream" {
  run _run_branch_switch -c fix/from-dev origin/development
  [ "${status}" -eq 0 ]
  [ "$(_current_branch)" = "fix/from-dev" ]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "$(git -C "${TEST_REPO_DIR}" rev-parse origin/development)" ]
  run git -C "${TEST_REPO_DIR}" config --get branch.fix/from-dev.merge
  [ "${status}" -ne 0 ]
}

@test "-c without a base starts at HEAD even when <remote>/<branch> exists, and warns" {
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feat/x
  echo "x" >"${TEST_REPO_DIR}/x.txt"
  git -C "${TEST_REPO_DIR}" add x.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: x"
  git -C "${TEST_REPO_DIR}" push --quiet origin feat/x
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" branch --quiet -D feat/x
  run _run_branch_switch -c feat/x
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"origin/feat/x already exists"* ]]
  [ "$(_current_branch)" = "feat/x" ]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "$(git -C "${TEST_REPO_DIR}" rev-parse main)" ]
  run git -C "${TEST_REPO_DIR}" config --get branch.feat/x.merge
  [ "${status}" -ne 0 ]
}

@test "-c <branch> <remote>/<branch> starts at the remote branch and tracks it" {
  git -C "${TEST_REPO_DIR}" checkout --quiet -b feat/y
  echo "y" >"${TEST_REPO_DIR}/y.txt"
  git -C "${TEST_REPO_DIR}" add y.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: y"
  git -C "${TEST_REPO_DIR}" push --quiet origin feat/y
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" branch --quiet -D feat/y
  run _run_branch_switch -c feat/y origin/feat/y
  [ "${status}" -eq 0 ]
  [ "$(_current_branch)" = "feat/y" ]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "$(git -C "${TEST_REPO_DIR}" rev-parse origin/feat/y)" ]
  [ "$(git -C "${TEST_REPO_DIR}" config --get branch.feat/y.merge)" = "refs/heads/feat/y" ]
}

@test "a bare HEAD is rejected even when refs/remotes/<remote>/HEAD exists" {
  git -C "${TEST_REPO_DIR}" remote set-head origin main
  run _run_branch_switch HEAD
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid branch name"* ]]
  [ "$(_current_branch)" = "main" ]
}

@test "-c refuses an existing branch" {
  run _run_branch_switch -c development
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"already exists"* ]]
  [ "$(_current_branch)" = "main" ]
}

@test "-c refuses an invalid branch name" {
  run _run_branch_switch -c "bad..name"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid branch name"* ]]
  [ "$(_current_branch)" = "main" ]
}

@test "-c refuses an invalid base ref" {
  run _run_branch_switch -c feat/x no-such-ref
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid base ref"* ]]
  [ "$(_current_branch)" = "main" ]
}

@test "-c from a detached HEAD keeps the commit" {
  git -C "${TEST_REPO_DIR}" checkout --quiet --detach development
  local sha
  sha="$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)"
  run _run_branch_switch -c rescue/detached
  [ "${status}" -eq 0 ]
  [ "$(_current_branch)" = "rescue/detached" ]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${sha}" ]
}

# ── Switch ────────────────────────────────────────────────────────────────────

@test "switches to an existing local branch" {
  run _run_branch_switch development
  [ "${status}" -eq 0 ]
  [ "$(_current_branch)" = "development" ]
}

@test "already on the branch is a no-op that exits 0" {
  run _run_branch_switch main
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Already on 'main'"* ]]
}

@test "a remote-only branch becomes a local tracking branch" {
  git -C "${TEST_REPO_DIR}" checkout --quiet -b remote-topic
  git -C "${TEST_REPO_DIR}" push --quiet origin remote-topic
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  git -C "${TEST_REPO_DIR}" branch --quiet -D remote-topic
  run _run_branch_switch remote-topic
  [ "${status}" -eq 0 ]
  [ "$(_current_branch)" = "remote-topic" ]
  [ "$(git -C "${TEST_REPO_DIR}" config --get branch.remote-topic.merge)" = "refs/heads/remote-topic" ]
}

@test "a branch that exists nowhere exits 1 and points to -c" {
  run _run_branch_switch ghost
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"-c ghost"* ]]
}

# ── Uncommitted work ──────────────────────────────────────────────────────────

@test "uncommitted changes are carried over to the new branch" {
  echo "v2" >"${TEST_REPO_DIR}/work.txt"
  run _run_branch_switch -c feat/keep-work
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"carried over"* ]]
  [ "$(_current_branch)" = "feat/keep-work" ]
  [ "$(cat "${TEST_REPO_DIR}/work.txt")" = "v2" ]
}

@test "a switch that would overwrite a change is refused and points to stash" {
  git -C "${TEST_REPO_DIR}" checkout --quiet -b other
  echo "other" >"${TEST_REPO_DIR}/work.txt"
  git -C "${TEST_REPO_DIR}" commit --quiet -am "chore: change work file on other"
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  echo "local edit" >"${TEST_REPO_DIR}/work.txt"
  run _run_branch_switch other
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"stash_work.sh push"* ]]
  [ "$(_current_branch)" = "main" ]
  [ "$(cat "${TEST_REPO_DIR}/work.txt")" = "local edit" ]
}

@test "an assume-unchanged path with a diverged change is warned about" {
  git -C "${TEST_REPO_DIR}" update-index --assume-unchanged work.txt
  echo "hidden edit" >"${TEST_REPO_DIR}/work.txt"
  run _run_branch_switch -c feat/hidden
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skip-worktree/assume-unchanged"* ]]
}

# ── Guards ────────────────────────────────────────────────────────────────────

@test "refuses while a merge is in progress" {
  git -C "${TEST_REPO_DIR}" checkout --quiet -b side
  echo "side" >"${TEST_REPO_DIR}/work.txt"
  git -C "${TEST_REPO_DIR}" commit --quiet -am "chore: side change"
  git -C "${TEST_REPO_DIR}" checkout --quiet main
  echo "main" >"${TEST_REPO_DIR}/work.txt"
  git -C "${TEST_REPO_DIR}" commit --quiet -am "chore: main change"
  run git -C "${TEST_REPO_DIR}" merge side
  [ "${status}" -ne 0 ]
  run _run_branch_switch -c feat/during-merge
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"MERGE_HEAD"* ]]
}

@test "refuses a branch checked out in another worktree" {
  create_test_worktree
  run _run_branch_switch worktree-topic
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"another worktree"* ]]
  [ "$(_current_branch)" = "main" ]
}

# ── Dry run ───────────────────────────────────────────────────────────────────

@test "an early exit still writes a result line to the log" {
  run _run_branch_switch -c feat/logged --dry-run
  [ "${status}" -eq 0 ]
  # One run in a fresh repo leaves exactly one log.
  local logs=("${TEST_REPO_DIR}"/logs/branch_switch_*.log)
  [ "${#logs[@]}" -eq 1 ]
  grep -q "^Result: dry run, branch not changed" "${logs[0]}"
  grep -q "^End Time:" "${logs[0]}"
}

@test "--dry-run prints the command and changes nothing" {
  run _run_branch_switch -c feat/dry --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Would run: git switch --no-track -c feat/dry"* ]]
  [ "$(_current_branch)" = "main" ]
  run git -C "${TEST_REPO_DIR}" rev-parse --verify --quiet refs/heads/feat/dry
  [ "${status}" -ne 0 ]
}
