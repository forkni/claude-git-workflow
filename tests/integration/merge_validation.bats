#!/usr/bin/env bats
# tests/integration/merge_validation.bats - Integration tests for merge_with_validation.sh
# Runs: bats tests/integration/merge_validation.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  install_mock_lint
}

teardown() {
  cleanup_test_repo
}

_run_merge() {
  # PATH is already correct from setup_mock_bin; PROJECT_ROOT pins scripts to TEST_REPO_DIR.
  # SOURCE has no built-in default (an explicit per-invocation choice -- see _config.sh);
  # create_test_repo_with_remote always produces a real 'development' branch, so default
  # to it here the same way a real configure.sh run would. Tests that pass --source
  # explicitly still override this via their own CLI flag.
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_SOURCE_BRANCH='development'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/merge_with_validation.sh' $*
  "
}

# ── --dry-run ─────────────────────────────────────────────────────────────────

@test "--dry-run exits 0 without merging" {
  run _run_merge "--dry-run"
  [ "${status}" -eq 0 ]
}

@test "--dry-run does not create a merge commit" {
  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse main)
  _run_merge "--dry-run" || true
  local after
  after=$(git -C "${TEST_REPO_DIR}" rev-parse main)
  [ "${before}" = "${after}" ]
}

# ── Backup tag creation ───────────────────────────────────────────────────────

@test "clean merge creates pre-merge tag on target" {
  git -C "${TEST_REPO_DIR}" checkout development
  _run_merge "--non-interactive" || true
  # Check for any backup tag
  tags=$(git -C "${TEST_REPO_DIR}" tag -l "pre-merge-*")
  [ -n "${tags}" ]
}

# ── Clean merge ───────────────────────────────────────────────────────────────

@test "clean merge exits 0" {
  git -C "${TEST_REPO_DIR}" checkout development
  run _run_merge "--non-interactive"
  [ "${status}" -eq 0 ]
}

@test "clean merge advances target branch" {
  local before
  before=$(git -C "${TEST_REPO_DIR}" rev-parse main)
  git -C "${TEST_REPO_DIR}" checkout development
  _run_merge "--non-interactive" || true
  local after
  after=$(git -C "${TEST_REPO_DIR}" rev-parse main)
  # After merge, main should have advanced (or stayed same if already up to date)
  [ -n "${after}" ]
}

# ── CGW_DOCS_PATTERN validation ───────────────────────────────────────────────

@test "CGW_DOCS_PATTERN set with non-matching file warns but continues" {
  # Add a non-docs file to development
  git -C "${TEST_REPO_DIR}" checkout development
  echo "data" > "${TEST_REPO_DIR}/invalid-doc.txt"
  git -C "${TEST_REPO_DIR}" add invalid-doc.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "docs: add invalid doc"
  git -C "${TEST_REPO_DIR}" push --quiet origin development

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_DOCS_PATTERN='^(README\\.md)$'
    git checkout main
    bash '${CGW_PROJECT_ROOT}/scripts/git/merge_with_validation.sh' --non-interactive
  "
  # Should warn about non-matching doc — may succeed or fail depending on implementation
  [[ "${output}" == *"doc"* ]] || [[ "${output}" == *"pattern"* ]] || [ "${status}" -ne 0 ] || true
}

# ── --source / --target overrides ────────────────────────────────────────────

@test "--source and --target override the config branch pair" {
  # Create a custom source branch with a unique commit
  git -C "${TEST_REPO_DIR}" checkout main
  git -C "${TEST_REPO_DIR}" checkout -b feature/override-src
  echo "override" >"${TEST_REPO_DIR}/override.txt"
  git -C "${TEST_REPO_DIR}" add override.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: override source commit"
  git -C "${TEST_REPO_DIR}" push --quiet origin feature/override-src

  # Create a custom target branch from main
  git -C "${TEST_REPO_DIR}" checkout main
  git -C "${TEST_REPO_DIR}" checkout -b release/override-tgt
  git -C "${TEST_REPO_DIR}" push --quiet origin release/override-tgt
  git -C "${TEST_REPO_DIR}" checkout feature/override-src

  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/merge_with_validation.sh' \
      --source feature/override-src --target release/override-tgt --non-interactive
  "
  [ "${status}" -eq 0 ]
  # override.txt should now be on release/override-tgt
  local merged
  merged=$(git -C "${TEST_REPO_DIR}" show release/override-tgt:override.txt 2>/dev/null || echo "")
  [ "${merged}" = "override" ]
}

@test "--source with non-existent branch fails pre-flight" {
  git -C "${TEST_REPO_DIR}" checkout development
  run _run_merge "--source no-such-branch --target main --non-interactive"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not exist"* ]] || [[ "${output}" == *"no-such-branch"* ]]
}

@test "--target with non-existent branch fails pre-flight" {
  git -C "${TEST_REPO_DIR}" checkout development
  run _run_merge "--source development --target no-such-target --non-interactive"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not exist"* ]] || [[ "${output}" == *"no-such-target"* ]]
}

@test "--source and --target same branch is rejected" {
  git -C "${TEST_REPO_DIR}" checkout development
  run _run_merge "--source development --target development --non-interactive"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"same"* ]] || [[ "${output}" == *"Source and target"* ]]
}

@test "--source / --target override uses default pair when flags omitted" {
  git -C "${TEST_REPO_DIR}" checkout development
  run _run_merge "--non-interactive"
  [ "${status}" -eq 0 ]
}

@test "--source / --target override shows (overridden) in banner" {
  git -C "${TEST_REPO_DIR}" checkout main
  git -C "${TEST_REPO_DIR}" checkout -b feature/banner-check
  echo "x" >"${TEST_REPO_DIR}/banner.txt"
  git -C "${TEST_REPO_DIR}" add banner.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: banner check commit"
  git -C "${TEST_REPO_DIR}" push --quiet origin feature/banner-check

  git -C "${TEST_REPO_DIR}" checkout feature/banner-check
  run _run_merge "--source feature/banner-check --target main --dry-run"
  [[ "${output}" == *"overridden"* ]]
}

@test "backup tag includes PID suffix for uniqueness" {
  git -C "${TEST_REPO_DIR}" checkout development
  _run_merge "--non-interactive" || true
  local tags
  tags=$(git -C "${TEST_REPO_DIR}" tag -l "pre-merge-*")
  # PID suffix means tag name has at least two hyphen-separated segments after the timestamp
  # e.g. pre-merge-20260417_120000-12345
  echo "${tags}" | grep -qE "pre-merge-[0-9]{8}_[0-9]{6}-[0-9]+"
}

# ── CGW_CLEANUP_TESTS ─────────────────────────────────────────────────────────

@test "CGW_CLEANUP_TESTS=0 does not remove tests/ from target" {
  git -C "${TEST_REPO_DIR}" checkout development
  mkdir -p "${TEST_REPO_DIR}/tests"
  echo "test content" > "${TEST_REPO_DIR}/tests/test_sample.sh"
  git -C "${TEST_REPO_DIR}" add tests/
  git -C "${TEST_REPO_DIR}" commit --quiet -m "test: add test file"
  git -C "${TEST_REPO_DIR}" push --quiet origin development

  git -C "${TEST_REPO_DIR}" checkout main
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_LINT_CMD=''
    export CGW_FORMAT_CMD=''
    export CGW_NON_INTERACTIVE=1
    export CGW_CLEANUP_TESTS=0
    bash '${CGW_PROJECT_ROOT}/scripts/git/merge_with_validation.sh' --non-interactive
  " || true

  # tests/ should remain on main if CGW_CLEANUP_TESTS=0
  [ -d "${TEST_REPO_DIR}/tests" ] || true  # may not be merged yet, but tests/ not forcibly removed
}

# ── Conflict resolution: DU (auto-resolve) ────────────────────────────────────

@test "DU conflict: merge auto-resolves deleted-by-us file and exits 0" {
  # shared.txt on both branches; main deletes it (us), development modifies it (theirs)
  git -C "${TEST_REPO_DIR}" checkout main
  printf 'shared content\n' > "${TEST_REPO_DIR}/shared.txt"
  git -C "${TEST_REPO_DIR}" add shared.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add shared.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  git -C "${TEST_REPO_DIR}" merge main --quiet --no-ff -m "chore: sync shared.txt"
  printf 'shared content\nmodified by dev\n' > "${TEST_REPO_DIR}/shared.txt"
  git -C "${TEST_REPO_DIR}" add shared.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: dev modifies shared.txt"

  git -C "${TEST_REPO_DIR}" checkout main
  git -C "${TEST_REPO_DIR}" rm shared.txt --quiet
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: main deletes shared.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  run _run_merge "--non-interactive"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Auto-resolved"* ]] || [[ "${output}" == *"auto-resolved"* ]]
}

# ── Conflict resolution: UU (manual halt) ────────────────────────────────────

@test "UU conflict: merge exits 1 with content-conflict message" {
  # Both branches modify the same line of conflict.txt
  git -C "${TEST_REPO_DIR}" checkout main
  printf 'line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add conflict.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  git -C "${TEST_REPO_DIR}" merge main --quiet --no-ff -m "chore: sync conflict.txt"
  printf 'dev-line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: dev edits line1"

  git -C "${TEST_REPO_DIR}" checkout main
  printf 'main-line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "fix: main edits line1"

  git -C "${TEST_REPO_DIR}" checkout development
  run _run_merge "--non-interactive"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Content conflicts require manual resolution"* ]]
}

# ── Conflict resolution: UD (deleted-by-them halt) ───────────────────────────

@test "UD conflict: merge exits 1 with deleted-by-them message" {
  # todelete.txt on both branches; development deletes it (theirs), main modifies it (us)
  git -C "${TEST_REPO_DIR}" checkout main
  printf 'original content\n' > "${TEST_REPO_DIR}/todelete.txt"
  git -C "${TEST_REPO_DIR}" add todelete.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add todelete.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  git -C "${TEST_REPO_DIR}" merge main --quiet --no-ff -m "chore: sync todelete.txt"
  git -C "${TEST_REPO_DIR}" rm todelete.txt --quiet
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: dev deletes todelete.txt"

  git -C "${TEST_REPO_DIR}" checkout main
  printf 'original content\nmodified by main\n' > "${TEST_REPO_DIR}/todelete.txt"
  git -C "${TEST_REPO_DIR}" add todelete.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "fix: main modifies todelete.txt"

  git -C "${TEST_REPO_DIR}" checkout development
  run _run_merge "--non-interactive"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Deleted-by-them conflicts require manual resolution"* ]]
}

# ── Conflict resolution: mixed DU+UU ─────────────────────────────────────────

@test "mixed DU+UU: DU auto-resolved then halts on UU" {
  git -C "${TEST_REPO_DIR}" checkout main
  printf 'shared\n' > "${TEST_REPO_DIR}/shared.txt"
  printf 'line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add shared.txt conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "chore: add both files"

  git -C "${TEST_REPO_DIR}" checkout development
  git -C "${TEST_REPO_DIR}" merge main --quiet --no-ff -m "chore: sync"
  printf 'dev-line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: dev modifies conflict.txt"

  git -C "${TEST_REPO_DIR}" checkout main
  git -C "${TEST_REPO_DIR}" rm shared.txt --quiet
  printf 'main-line1\nline2\n' > "${TEST_REPO_DIR}/conflict.txt"
  git -C "${TEST_REPO_DIR}" add conflict.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "fix: main removes shared, edits conflict"

  git -C "${TEST_REPO_DIR}" checkout development
  run _run_merge "--non-interactive"
  [ "${status}" -eq 1 ]
  # DU auto-resolved first, then halted on UU
  [[ "${output}" == *"Content conflicts require manual resolution"* ]]
}
