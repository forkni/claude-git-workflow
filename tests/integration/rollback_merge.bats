#!/usr/bin/env bats
# tests/integration/rollback_merge.bats - Integration tests for rollback_merge.sh
# Runs: bats tests/integration/rollback_merge.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout --quiet main
}

teardown() {
  cleanup_test_repo
}

# ── branch guard ──────────────────────────────────────────────────────────────

@test "running from non-target branch exits 1" {
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  run run_script rollback_merge.sh --non-interactive --target HEAD~1
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"target branch"* ]] || [[ "${output}" == *"Not on"* ]]
}

# ── uncommitted changes guard ─────────────────────────────────────────────────

@test "uncommitted changes in non-interactive mode exits 1" {
  echo "dirty" > "${TEST_REPO_DIR}/dirty.txt"
  git -C "${TEST_REPO_DIR}" add dirty.txt
  run run_script rollback_merge.sh --non-interactive --target HEAD~1
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Aborting"* ]] || [[ "${output}" == *"uncommitted"* ]] || [[ "${output}" == *"Uncommitted"* ]]
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run shows rollback target without resetting" {
  # Need at least two commits for HEAD~1 to be valid
  echo "extra" > "${TEST_REPO_DIR}/extra.txt"
  git -C "${TEST_REPO_DIR}" add extra.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: second commit"

  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script rollback_merge.sh --non-interactive --dry-run --target HEAD~1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ry run"* ]] || [[ "${output}" == *"DRY"* ]] || [[ "${output}" == *"Dry"* ]]

  local head_after
  head_after=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  [ "${head_before}" = "${head_after}" ]
}

# ── --target with explicit ref ─────────────────────────────────────────────────

@test "--target HEAD~1 resets non-interactively to the previous commit" {
  # Create a second commit so HEAD~1 exists
  echo "extra" > "${TEST_REPO_DIR}/extra.txt"
  git -C "${TEST_REPO_DIR}" add extra.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: second commit"

  run run_script rollback_merge.sh --non-interactive --target HEAD~1
  [ "${status}" -eq 0 ]
}

# ── --target with explicit backup tag ─────────────────────────────────────────

@test "--target with explicit backup tag rolls back to that tag" {
  # Create a backup tag at HEAD, then add one commit
  local before_sha
  before_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  git -C "${TEST_REPO_DIR}" tag "pre-merge-backup-20250101_000000" HEAD
  echo "after" > "${TEST_REPO_DIR}/after.txt"
  git -C "${TEST_REPO_DIR}" add after.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: after tag commit"

  run run_script rollback_merge.sh --non-interactive --target pre-merge-backup-20250101_000000
  [ "${status}" -eq 0 ]

  # HEAD should be back to before_sha
  local current_sha
  current_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  [ "${current_sha}" = "${before_sha}" ]
}

@test "--target with new-format pre-merge tag (no -backup- infix) rolls back correctly" {
  local before_sha
  before_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  git -C "${TEST_REPO_DIR}" tag "pre-merge-20250101_000000-12345" HEAD
  echo "after" > "${TEST_REPO_DIR}/after.txt"
  git -C "${TEST_REPO_DIR}" add after.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: after tag commit"

  run run_script rollback_merge.sh --non-interactive --target pre-merge-20250101_000000-12345
  [ "${status}" -eq 0 ]

  local current_sha
  current_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)
  [ "${current_sha}" = "${before_sha}" ]
}

# ── backup tag before hard reset (E1) ──────────────────────────────────────────

@test "--hard rollback creates a pre-rollback-* backup tag before resetting" {
  # Two commits so HEAD~1 is a valid rollback target
  echo "extra" > "${TEST_REPO_DIR}/extra.txt"
  git -C "${TEST_REPO_DIR}" add extra.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: second commit"

  local discarded_sha
  discarded_sha=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script rollback_merge.sh --non-interactive --target HEAD~1
  [ "${status}" -eq 0 ]

  # A backup tag must now exist and point at the discarded HEAD (recoverable).
  local tag
  tag=$(git -C "${TEST_REPO_DIR}" tag -l 'pre-rollback-*' | head -1)
  [ -n "${tag}" ]
  local tagged_sha
  tagged_sha=$(git -C "${TEST_REPO_DIR}" rev-parse "${tag}")
  [ "${tagged_sha}" = "${discarded_sha}" ]
}

# ── --revert mode: reject root commit (R1) ────────────────────────────────────

@test "--revert refuses when rollback target is a root commit" {
  local root_sha
  root_sha=$(git -C "${TEST_REPO_DIR}" rev-list --max-parents=0 HEAD)

  run run_script rollback_merge.sh --non-interactive --revert --target "${root_sha}"
  [ "${status}" -eq 1 ]
  [[ "${output}" != *"syntax error"* ]]
  [[ "${output}" == *"requires a merge commit"* ]]
  [[ "${output}" == *"has 0 parent(s)"* ]]
  [ -f "${TEST_REPO_DIR}/README.md" ]
}

@test "--non-interactive hard rollback refuses when --target omitted and no backup tag exists (E1)" {
  echo "extra" > "${TEST_REPO_DIR}/extra.txt"
  git -C "${TEST_REPO_DIR}" add extra.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: second commit"

  run run_script rollback_merge.sh --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Refusing hard rollback: no --target specified and no pre-merge backup tag found"* ]]
}

# ── --revert / hard-mode target guards (R3/R4) ─────────────────────────────────

# Two --no-ff merges into main (feature-1 then feature-2), with pre-merge tags
# taken before each one. Sets MERGE1_SHA, MERGE2_SHA, TAG1, TAG2.
_two_merge_history() {
  local repo="${TEST_REPO_DIR}"
  local n
  for n in 1 2; do
    git -C "${repo}" checkout --quiet -b "feature-${n}" main
    echo "f${n}" >"${repo}/feature${n}.txt"
    git -C "${repo}" add "feature${n}.txt"
    git -C "${repo}" commit --quiet -m "feat: feature ${n}"
    git -C "${repo}" checkout --quiet main
    git -C "${repo}" tag "pre-merge-2025010${n}_000000-${n}" main
    git -C "${repo}" merge --quiet --no-ff -m "Merge feature-${n}" "feature-${n}"
    if [[ ${n} -eq 1 ]]; then
      MERGE1_SHA=$(git -C "${repo}" rev-parse HEAD)
    else
      MERGE2_SHA=$(git -C "${repo}" rev-parse HEAD)
    fi
  done
  TAG1="pre-merge-20250101_000000-1"
  TAG2="pre-merge-20250102_000000-2"
}

@test "--revert --non-interactive reverts the merge at HEAD, not the previous merge (R3)" {
  _two_merge_history

  run run_script rollback_merge.sh --non-interactive --revert
  [ "${status}" -eq 0 ]

  # Feature 2 is gone, feature 1 (the previous merge) is untouched.
  [ ! -f "${TEST_REPO_DIR}/feature2.txt" ]
  [ -f "${TEST_REPO_DIR}/feature1.txt" ]
  [[ "$(git -C "${TEST_REPO_DIR}" log -1 --format=%s)" == "Revert \"Merge feature-2\""* ]]
}

@test "--revert --non-interactive refuses when HEAD is not a merge and no --target (R3)" {
  _two_merge_history
  echo "plain" >"${TEST_REPO_DIR}/plain.txt"
  git -C "${TEST_REPO_DIR}" add plain.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: plain commit"
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script rollback_merge.sh --non-interactive --revert
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"HEAD is not a merge commit"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
}

@test "--revert with an explicit merge --target reverts that merge" {
  _two_merge_history

  run run_script rollback_merge.sh --non-interactive --revert --target "${MERGE1_SHA}"
  [ "${status}" -eq 0 ]
  [ ! -f "${TEST_REPO_DIR}/feature1.txt" ]
  [ -f "${TEST_REPO_DIR}/feature2.txt" ]
}

@test "--revert accepts an annotated tag on a merge as --target (peeled)" {
  _two_merge_history
  git -C "${TEST_REPO_DIR}" tag -a -m "release" rel-1 "${MERGE2_SHA}"

  run run_script rollback_merge.sh --non-interactive --revert --target rel-1
  [ "${status}" -eq 0 ]
  [ ! -f "${TEST_REPO_DIR}/feature2.txt" ]
}

@test "--revert success prints the revert-the-revert re-merge warning" {
  _two_merge_history

  run run_script rollback_merge.sh --non-interactive --revert
  [ "${status}" -eq 0 ]
  local revert_sha
  revert_sha=$(git -C "${TEST_REPO_DIR}" rev-parse --short HEAD)
  [[ "${output}" == *"revert the revert"* ]]
  [[ "${output}" == *"git revert ${revert_sha}"* ]]
}

@test "--revert --dry-run does not change HEAD" {
  _two_merge_history
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script rollback_merge.sh --non-interactive --revert --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Would revert merge"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
}

@test "hard rollback auto-picks the backup tag that equals HEAD^1 (R4)" {
  _two_merge_history

  run run_script rollback_merge.sh --non-interactive
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "$(git -C "${TEST_REPO_DIR}" rev-parse "${TAG2}^{commit}")" ]
  [ ! -f "${TEST_REPO_DIR}/feature2.txt" ]
  [ -f "${TEST_REPO_DIR}/feature1.txt" ]
}

@test "hard rollback refuses a stale latest backup tag that is not HEAD^1 (R4)" {
  _two_merge_history
  # Unrelated later work on top of the last merge: the newest tag is now stale.
  echo "later" >"${TEST_REPO_DIR}/later.txt"
  git -C "${TEST_REPO_DIR}" add later.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: later work"
  git -C "${TEST_REPO_DIR}" commit --quiet --allow-empty -m "chore: even later work"
  local head_before
  head_before=$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)

  run run_script rollback_merge.sh --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"is not the state just before HEAD's merge"* ]]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "${head_before}" ]
  [ -f "${TEST_REPO_DIR}/later.txt" ]
}

@test "hard rollback refuses a backup tag that is not an ancestor of HEAD (R4)" {
  local repo="${TEST_REPO_DIR}"
  git -C "${repo}" checkout --quiet -b elsewhere
  echo "x" >"${repo}/elsewhere.txt"
  git -C "${repo}" add elsewhere.txt
  git -C "${repo}" commit --quiet -m "chore: elsewhere"
  git -C "${repo}" tag "pre-merge-20250301_000000-9" elsewhere
  git -C "${repo}" checkout --quiet main
  echo "extra" >"${repo}/extra.txt"
  git -C "${repo}" add extra.txt
  git -C "${repo}" commit --quiet -m "chore: extra"
  local head_before
  head_before=$(git -C "${repo}" rev-parse HEAD)

  run run_script rollback_merge.sh --non-interactive
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"unrelated"* ]]
  [ "$(git -C "${repo}" rev-parse HEAD)" = "${head_before}" ]
}

@test "hard rollback --target still accepts a stale tag explicitly (unchanged behaviour)" {
  _two_merge_history
  echo "later" >"${TEST_REPO_DIR}/later.txt"
  git -C "${TEST_REPO_DIR}" add later.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: later work"

  run run_script rollback_merge.sh --non-interactive --target "${TAG1}"
  [ "${status}" -eq 0 ]
  [ "$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)" = "$(git -C "${TEST_REPO_DIR}" rev-parse "${TAG1}^{commit}")" ]
}
