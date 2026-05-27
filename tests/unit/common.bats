#!/usr/bin/env bats
# tests/unit/common.bats - Unit tests for _common.sh utility functions
# Runs: bats tests/unit/common.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

# ── Test setup/teardown ────────────────────────────────────────────────────────
# One repo shared across all 101 tests in this file. BATS_FILE_TMPDIR is
# auto-cleaned by Bats after teardown_file — no manual cleanup needed.
# Tests must not rename branches or hard-reset HEAD; tag/add/commit mutations
# are safe because they are either namespaced or ordered to run after any test
# that checks pre-mutation state (see audit in commit message).

setup_file() {
  setup_file_create_test_repo
}

setup() {
  cd "${TEST_REPO_DIR}"
  # ensure_no_stale_index_lock tests leave .git/index.lock on purpose (testing
  # the "refuse" path). Clear it so subsequent tests can run git commands cleanly.
  rm -f "${TEST_REPO_DIR}/.git/index.lock"
  export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
  # shellcheck source=scripts/git/_common.sh
  source "${CGW_PROJECT_ROOT}/scripts/git/_common.sh"
}

# ── err() ──────────────────────────────────────────────────────────────────────

@test "err() writes [ERROR] prefix to stderr" {
  run bash -c "
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    err 'something went wrong' 2>/dev/null
  "
  [ "${status}" -eq 0 ]
  # Nothing on stdout (err() writes to stderr only)
  [ -z "${output}" ]
}

@test "err() message appears on stderr" {
  result=$(bash -c "
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    err 'test error message'
  " 2>&1)
  [[ "${result}" == *"[ERROR] test error message"* ]]
}

@test "err() supports multiple arguments" {
  result=$(bash -c "
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    err 'part1' 'part2' 'part3'
  " 2>&1)
  [[ "${result}" == *"[ERROR]"* ]]
  [[ "${result}" == *"part1"* ]]
}

# ── get_timestamp() ────────────────────────────────────────────────────────────

@test "get_timestamp() sets \$timestamp variable" {
  get_timestamp
  [ -n "${timestamp}" ]
}

@test "get_timestamp() format matches YYYYMMDD_HHMMSS" {
  get_timestamp
  [[ "${timestamp}" =~ ^[0-9]{8}_[0-9]{6}$ ]]
}

# ── init_logging() ────────────────────────────────────────────────────────────

@test "init_logging() creates logs/ directory" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}" init_logging "test_script"
  [ -d "${TEST_REPO_DIR}/logs" ]
}

@test "init_logging() sets \$logfile path" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}" init_logging "test_script"
  [ -n "${logfile}" ]
  [[ "${logfile}" == "${TEST_REPO_DIR}/logs/test_script_"*.log ]]
}

@test "init_logging() sets \$reportfile path" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}" init_logging "test_script"
  [ -n "${reportfile}" ]
  [[ "${reportfile}" == "${TEST_REPO_DIR}/logs/test_script_analysis_"*.log ]]
}

@test "init_logging() logfile path includes timestamp" {
  cd "${TEST_REPO_DIR}"
  init_logging "myscript"
  [[ "${logfile}" =~ myscript_[0-9]{8}_[0-9]{6}\.log$ ]]
}

# ── get_lint_exclusions() ─────────────────────────────────────────────────────

@test "get_lint_exclusions() copies CGW_LINT_EXCLUDES to RUFF_CHECK_EXCLUDE" {
  CGW_LINT_EXCLUDES="--extend-exclude logs"
  get_lint_exclusions
  [ "${RUFF_CHECK_EXCLUDE}" = "--extend-exclude logs" ]
}

@test "get_lint_exclusions() copies CGW_FORMAT_EXCLUDES to RUFF_FORMAT_EXCLUDE" {
  CGW_FORMAT_EXCLUDES="--exclude .venv"
  get_lint_exclusions
  [ "${RUFF_FORMAT_EXCLUDE}" = "--exclude .venv" ]
}

# ── get_python_path() ─────────────────────────────────────────────────────────

@test "get_python_path() with CGW_NO_VENV=1 sets PYTHON_BIN empty" {
  CGW_NO_VENV=1 get_python_path
  [ "${PYTHON_BIN}" = "" ]
}

@test "get_python_path() with CGW_NO_VENV=1 sets PYTHON_EXT empty" {
  CGW_NO_VENV=1 get_python_path
  [ "${PYTHON_EXT}" = "" ]
}

@test "get_python_path() with SKIP_VENV=1 returns 0" {
  run bash -c "
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    SKIP_VENV=1 get_python_path
  "
  [ "${status}" -eq 0 ]
}

@test "get_python_path() detects .venv/bin on Unix-like layout" {
  cd "${TEST_REPO_DIR}"
  mkdir -p ".venv/bin"
  get_python_path
  [ "${PYTHON_BIN}" = ".venv/bin" ]
  [ "${PYTHON_EXT}" = "" ]
  rm -rf .venv
}

@test "get_python_path() without .venv and no ruff returns error" {
  # Run in a dir that has no .venv and PATH with no ruff
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PATH='/usr/bin:/bin'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    get_python_path
  "
  # Either exits 1 or prints ERROR
  [[ "${status}" -ne 0 ]] || [[ "${output}" == *"ERROR"* ]]
}

# ── log_section_start/end() ───────────────────────────────────────────────────

@test "log_section_start() outputs section header" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run log_section_start "MY-SECTION" "${logfile}"
  [[ "${output}" == *"MY-SECTION"* ]]
}

@test "log_section_start() outputs Started" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run log_section_start "MY-SECTION" "${logfile}"
  [[ "${output}" == *"Started"* ]]
}

@test "log_section_end() with exit_code=0 outputs PASSED" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  log_section_start "MYSEC" "${logfile}"
  run log_section_end "MYSEC" "${logfile}" "0"
  [[ "${output}" == *"PASSED"* ]]
}

@test "log_section_end() with exit_code=1 outputs FAILED" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  log_section_start "MYSEC" "${logfile}"
  run log_section_end "MYSEC" "${logfile}" "1"
  [[ "${output}" == *"FAILED"* ]]
}

# ── run_tool_with_logging() ───────────────────────────────────────────────────

@test "run_tool_with_logging() captures exit code from command" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run run_tool_with_logging "MOCK" "${logfile}" bash -c "exit 0"
  [ "${status}" -eq 0 ]
}

@test "run_tool_with_logging() propagates non-zero exit" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run run_tool_with_logging "MOCK" "${logfile}" bash -c "exit 2"
  [ "${status}" -eq 2 ]
}

@test "run_tool_with_logging() sets TOOL_ERROR_COUNT for diagnostic output" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run_tool_with_logging "MOCK" "${logfile}" bash -c "
    echo 'src/foo.py:10:5: E501 line too long'
    echo 'src/bar.py:22:1: F401 unused import'
    exit 1
  " || true
  [ "${TOOL_ERROR_COUNT}" -eq 2 ]
}

@test "run_tool_with_logging() TOOL_ERROR_COUNT=0 for clean output" {
  cd "${TEST_REPO_DIR}"
  init_logging "test"
  run_tool_with_logging "MOCK" "${logfile}" bash -c "echo 'All good'; exit 0"
  [ "${TOOL_ERROR_COUNT}" -eq 0 ]
}

# ── ensure_no_stale_index_lock() ─────────────────────────────────────────────
# Helpers — back-date a lock file to simulate a stale one.

_make_stale_lock() {
  local seconds_ago="${1:-60}"
  local f="${TEST_REPO_DIR}/.git/index.lock"
  : >"${f}"
  # GNU touch first; fall back to epoch-arithmetic for BSD/macOS
  if ! touch -d "${seconds_ago} seconds ago" "${f}" 2>/dev/null; then
    local epoch
    epoch=$(( $(date +%s) - seconds_ago ))
    touch -t "$(date -u -r "${epoch}" +%Y%m%d%H%M.%S 2>/dev/null \
              || date -u -d "@${epoch}" +%Y%m%d%H%M.%S)" "${f}"
  fi
}

_make_fresh_lock() {
  : >"${TEST_REPO_DIR}/.git/index.lock"
}

@test "ensure_no_stale_index_lock: returns 0 with no lock present" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}"
  run ensure_no_stale_index_lock
  [ "${status}" -eq 0 ]
}

@test "ensure_no_stale_index_lock: removes stale lock with default config" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}"
  _make_stale_lock 60
  [ -f "${TEST_REPO_DIR}/.git/index.lock" ]
  CGW_AUTO_REMOVE_INDEX_LOCK=1 CGW_INDEX_LOCK_MAX_AGE_SECONDS=30 \
    CGW_INDEX_LOCK_WAIT_SECONDS=0 run ensure_no_stale_index_lock
  [ "${status}" -eq 0 ]
  [ ! -f "${TEST_REPO_DIR}/.git/index.lock" ]
  [[ "${output}" == *"[cgw-lock]"* ]]
  [[ "${output}" == *"Removing stale"* ]]
}

@test "ensure_no_stale_index_lock: refuses stale lock when auto-remove disabled" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}"
  _make_stale_lock 60
  CGW_AUTO_REMOVE_INDEX_LOCK=0 CGW_INDEX_LOCK_MAX_AGE_SECONDS=30 \
    CGW_INDEX_LOCK_WAIT_SECONDS=0 run ensure_no_stale_index_lock
  [ "${status}" -eq 1 ]
  [ -f "${TEST_REPO_DIR}/.git/index.lock" ]
  [[ "${output}" == *"CGW_AUTO_REMOVE_INDEX_LOCK=0"* ]]
}

@test "ensure_no_stale_index_lock: returns 0 when fresh lock clears during wait" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}"
  _make_fresh_lock
  ( sleep 1 && rm -f "${TEST_REPO_DIR}/.git/index.lock" ) &
  local bg_pid=$!
  CGW_AUTO_REMOVE_INDEX_LOCK=1 CGW_INDEX_LOCK_MAX_AGE_SECONDS=30 \
    CGW_INDEX_LOCK_WAIT_SECONDS=5 run ensure_no_stale_index_lock
  wait "${bg_pid}" 2>/dev/null || true
  [ "${status}" -eq 0 ]
  [ ! -f "${TEST_REPO_DIR}/.git/index.lock" ]
}

@test "ensure_no_stale_index_lock: returns 1 when fresh lock persists past wait" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}"
  _make_fresh_lock
  CGW_AUTO_REMOVE_INDEX_LOCK=1 CGW_INDEX_LOCK_MAX_AGE_SECONDS=999 \
    CGW_INDEX_LOCK_WAIT_SECONDS=2 run ensure_no_stale_index_lock
  [ "${status}" -eq 1 ]
  [ -f "${TEST_REPO_DIR}/.git/index.lock" ]
  [[ "${output}" == *"still present"* ]]
}

@test "ensure_no_stale_index_lock: removes lock after it ages past threshold during wait" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}"
  _make_fresh_lock
  # max_age=1s, wait=4s → after waiting the lock will be >1s old → removed
  CGW_AUTO_REMOVE_INDEX_LOCK=1 CGW_INDEX_LOCK_MAX_AGE_SECONDS=1 \
    CGW_INDEX_LOCK_WAIT_SECONDS=4 run ensure_no_stale_index_lock
  [ "${status}" -eq 0 ]
  [ ! -f "${TEST_REPO_DIR}/.git/index.lock" ]
}

@test "ensure_no_stale_index_lock: returns 2 outside a git repo" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  run bash -c "
    cd '${tmpdir}'
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    PROJECT_ROOT='${tmpdir}'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    ensure_no_stale_index_lock
  "
  [ "${status}" -eq 2 ]
  rm -rf "${tmpdir}"
}

@test "ensure_no_stale_index_lock: treats future-dated mtime as fresh (clock skew)" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}"
  _make_fresh_lock
  # Bump mtime 120s into the future to simulate clock skew
  local future_epoch
  future_epoch=$(( $(date +%s) + 120 ))
  touch -t "$(date -u -d "@${future_epoch}" +%Y%m%d%H%M.%S 2>/dev/null \
            || date -u -r "${future_epoch}" +%Y%m%d%H%M.%S)" \
    "${TEST_REPO_DIR}/.git/index.lock" 2>/dev/null || true
  # age=-120 clamped to 0 → treated as fresh → refuses even with wait=0
  CGW_AUTO_REMOVE_INDEX_LOCK=1 CGW_INDEX_LOCK_MAX_AGE_SECONDS=30 \
    CGW_INDEX_LOCK_WAIT_SECONDS=0 run ensure_no_stale_index_lock
  [ "${status}" -eq 1 ]
  [ -f "${TEST_REPO_DIR}/.git/index.lock" ]
}

@test "ensure_no_stale_index_lock: refuses when MERGE_HEAD present (op in progress)" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}"
  _make_stale_lock 60
  touch "${TEST_REPO_DIR}/.git/MERGE_HEAD"
  CGW_AUTO_REMOVE_INDEX_LOCK=1 CGW_INDEX_LOCK_MAX_AGE_SECONDS=30 \
    CGW_INDEX_LOCK_WAIT_SECONDS=0 run ensure_no_stale_index_lock
  [ "${status}" -eq 1 ]
  [ -f "${TEST_REPO_DIR}/.git/index.lock" ]
  [[ "${output}" == *"REFUSED"* ]]
  rm -f "${TEST_REPO_DIR}/.git/MERGE_HEAD"
}

@test "ensure_no_stale_index_lock: refuses when CHERRY_PICK_HEAD present" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}"
  _make_stale_lock 60
  touch "${TEST_REPO_DIR}/.git/CHERRY_PICK_HEAD"
  CGW_AUTO_REMOVE_INDEX_LOCK=1 CGW_INDEX_LOCK_MAX_AGE_SECONDS=30 \
    CGW_INDEX_LOCK_WAIT_SECONDS=0 run ensure_no_stale_index_lock
  [ "${status}" -eq 1 ]
  [ -f "${TEST_REPO_DIR}/.git/index.lock" ]
  rm -f "${TEST_REPO_DIR}/.git/CHERRY_PICK_HEAD"
}

@test "ensure_no_stale_index_lock: refuses when rebase-merge dir present" {
  cd "${TEST_REPO_DIR}"
  PROJECT_ROOT="${TEST_REPO_DIR}"
  _make_stale_lock 60
  mkdir -p "${TEST_REPO_DIR}/.git/rebase-merge"
  CGW_AUTO_REMOVE_INDEX_LOCK=1 CGW_INDEX_LOCK_MAX_AGE_SECONDS=30 \
    CGW_INDEX_LOCK_WAIT_SECONDS=0 run ensure_no_stale_index_lock
  [ "${status}" -eq 1 ]
  [ -f "${TEST_REPO_DIR}/.git/index.lock" ]
  rm -rf "${TEST_REPO_DIR}/.git/rebase-merge"
}

# ── cgw_create_backup_tag() ──────────────────────────────────────────────────

@test "cgw_create_backup_tag: sets CGW_BACKUP_TAG to pre-<op>-<ts>-<pid> format" {
  cd "${TEST_REPO_DIR}"
  cgw_create_backup_tag merge
  [[ "${CGW_BACKUP_TAG}" =~ ^pre-merge-[0-9]{8}_[0-9]{6}-[0-9]+$ ]]
}

@test "cgw_create_backup_tag: creates the git tag in the repo" {
  cd "${TEST_REPO_DIR}"
  cgw_create_backup_tag undo-commit
  git tag -l "${CGW_BACKUP_TAG}" | grep -q "${CGW_BACKUP_TAG}"
}

@test "cgw_create_backup_tag: unknown op returns 1 with error" {
  run bash -c "
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    cd '${TEST_REPO_DIR}'
    cgw_create_backup_tag bogus-op 2>&1
  "
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"unknown op"* ]]
}

# ── cgw_backup_tag_glob() ────────────────────────────────────────────────────

@test "cgw_backup_tag_glob: no arg yields one pattern per op" {
  result=$(cgw_backup_tag_glob)
  line_count=$(printf '%s\n' "${result}" | wc -l | tr -d ' ')
  [ "${line_count}" -eq "${#CGW_BACKUP_OPS[@]}" ]
}

@test "cgw_backup_tag_glob: with op echoes single glob" {
  [ "$(cgw_backup_tag_glob merge)" = "pre-merge-*" ]
}

# ── cgw_list_backup_tags() ───────────────────────────────────────────────────

@test "cgw_list_backup_tags: with op returns only that op's tags" {
  cd "${TEST_REPO_DIR}"
  git tag "pre-merge-20200101_000000-1"
  git tag "pre-rebase-20200101_000000-2"
  result=$(cgw_list_backup_tags merge)
  echo "${result}" | grep -q "pre-merge-"
  ! echo "${result}" | grep -q "pre-rebase-"
}

@test "cgw_list_backup_tags: no arg returns tags from all ops" {
  cd "${TEST_REPO_DIR}"
  git tag "pre-merge-20200102_000000-1"
  git tag "pre-bisect-20200102_000000-2"
  result=$(cgw_list_backup_tags)
  echo "${result}" | grep -q "pre-merge-"
  echo "${result}" | grep -q "pre-bisect-"
}

# ── cgw_is_local_file() ──────────────────────────────────────────────────────

@test "cgw_is_local_file: plain file exact match returns 0" {
  CGW_LOCAL_FILES="CLAUDE.md MEMORY.md"
  CGW_LOCAL_FILES_EXEMPT=""
  cgw_is_local_file "CLAUDE.md"
}

@test "cgw_is_local_file: trailing chars do NOT match (anchoring)" {
  CGW_LOCAL_FILES="MEMORY"
  CGW_LOCAL_FILES_EXEMPT=""
  run cgw_is_local_file "MEMORY.md"
  [ "${status}" -eq 1 ]
}

@test "cgw_is_local_file: substring does NOT match (anchoring)" {
  CGW_LOCAL_FILES="logs"
  CGW_LOCAL_FILES_EXEMPT=""
  run cgw_is_local_file "logs.md"
  [ "${status}" -eq 1 ]
}

@test "cgw_is_local_file: directory entry matches file inside" {
  CGW_LOCAL_FILES=".claude/"
  CGW_LOCAL_FILES_EXEMPT=""
  cgw_is_local_file ".claude/foo.md"
}

@test "cgw_is_local_file: directory entry matches the directory itself" {
  CGW_LOCAL_FILES=".claude/"
  CGW_LOCAL_FILES_EXEMPT=""
  cgw_is_local_file ".claude"
}

@test "cgw_is_local_file: directory entry does NOT match similar-prefix dir (bug #6 regression)" {
  CGW_LOCAL_FILES=".claude/"
  CGW_LOCAL_FILES_EXEMPT=""
  run cgw_is_local_file ".claudefoo"
  [ "${status}" -eq 1 ]
  run cgw_is_local_file ".claudefoo/bar"
  [ "${status}" -eq 1 ]
}

@test "cgw_is_local_file: exempt suppresses match for plain file (bug #4 regression)" {
  CGW_LOCAL_FILES="CLAUDE.md"
  CGW_LOCAL_FILES_EXEMPT="CLAUDE.md"
  run cgw_is_local_file "CLAUDE.md"
  [ "${status}" -eq 1 ]
}

@test "cgw_is_local_file: exempt suppresses match for directory entry" {
  CGW_LOCAL_FILES=".claude/"
  CGW_LOCAL_FILES_EXEMPT=".claude/keep.md"
  run cgw_is_local_file ".claude/keep.md"
  [ "${status}" -eq 1 ]
  cgw_is_local_file ".claude/other.md"
}

@test "cgw_is_local_file: empty CGW_LOCAL_FILES returns 1 for any path" {
  CGW_LOCAL_FILES=""
  CGW_LOCAL_FILES_EXEMPT=""
  run cgw_is_local_file "CLAUDE.md"
  [ "${status}" -eq 1 ]
}

# ── cgw_filter_local_files() ─────────────────────────────────────────────────

@test "cgw_filter_local_files: stdin filters and echoes matches" {
  CGW_LOCAL_FILES="CLAUDE.md .claude/"
  CGW_LOCAL_FILES_EXEMPT=""
  result=$(printf '%s\n' "CLAUDE.md" "src/foo.py" ".claude/bar" "README.md" | cgw_filter_local_files)
  echo "${result}" | grep -qx "CLAUDE.md"
  echo "${result}" | grep -qx ".claude/bar"
  ! echo "${result}" | grep -qx "src/foo.py"
  ! echo "${result}" | grep -qx "README.md"
}

@test "cgw_filter_local_files: returns 1 when no matches" {
  CGW_LOCAL_FILES="CLAUDE.md"
  CGW_LOCAL_FILES_EXEMPT=""
  run bash -c "
    SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    CGW_LOCAL_FILES='CLAUDE.md'
    CGW_LOCAL_FILES_EXEMPT=''
    printf '%s\n' 'src/foo.py' 'README.md' | cgw_filter_local_files
  "
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "cgw_filter_local_files: positional args filter and echo matches" {
  CGW_LOCAL_FILES="CLAUDE.md .claude/"
  CGW_LOCAL_FILES_EXEMPT=""
  result=$(cgw_filter_local_files "CLAUDE.md" "src/foo.py" ".claude/bar")
  echo "${result}" | grep -qx "CLAUDE.md"
  echo "${result}" | grep -qx ".claude/bar"
  ! echo "${result}" | grep -qx "src/foo.py"
}

# ── cgw_classify_conflicts() ─────────────────────────────────────────────────

@test "cgw_classify_conflicts: empty input sets TOTAL=0 and returns 1" {
  run cgw_classify_conflicts ""
  [ "${status}" -eq 1 ]
  [ "${CGW_CONFLICT_TOTAL}" -eq 0 ]
}

@test "cgw_classify_conflicts: single DU line populates DU_FILES and TOTAL=1" {
  cgw_classify_conflicts "DU src/foo.py"
  [ "${CGW_CONFLICT_TOTAL}" -eq 1 ]
  [ "${#CGW_CONFLICT_DU_FILES[@]}" -eq 1 ]
  [ "${CGW_CONFLICT_DU_FILES[0]}" = "src/foo.py" ]
  [ "${#CGW_CONFLICT_UU_FILES[@]}" -eq 0 ]
}

@test "cgw_classify_conflicts: single DD line populates DD_FILES" {
  cgw_classify_conflicts "DD old/file.txt"
  [ "${CGW_CONFLICT_TOTAL}" -eq 1 ]
  [ "${#CGW_CONFLICT_DD_FILES[@]}" -eq 1 ]
  [ "${CGW_CONFLICT_DD_FILES[0]}" = "old/file.txt" ]
}

@test "cgw_classify_conflicts: UU, AU, AA, UD, AD, DA each populate their array" {
  cgw_classify_conflicts "UU a.py
AU b.py
AA c.py
UD d.py
AD e.py
DA f.py"
  [ "${CGW_CONFLICT_TOTAL}" -eq 6 ]
  [ "${#CGW_CONFLICT_UU_FILES[@]}" -eq 1 ]
  [ "${#CGW_CONFLICT_AU_FILES[@]}" -eq 1 ]
  [ "${#CGW_CONFLICT_AA_FILES[@]}" -eq 1 ]
  [ "${#CGW_CONFLICT_UD_FILES[@]}" -eq 1 ]
  [ "${#CGW_CONFLICT_AD_FILES[@]}" -eq 1 ]
  [ "${#CGW_CONFLICT_DA_FILES[@]}" -eq 1 ]
}

@test "cgw_classify_conflicts: mixed DU+UU assigns to correct arrays" {
  cgw_classify_conflicts "DU a.py
UU b.py
DU c.py"
  [ "${CGW_CONFLICT_TOTAL}" -eq 3 ]
  [ "${#CGW_CONFLICT_DU_FILES[@]}" -eq 2 ]
  [ "${#CGW_CONFLICT_UU_FILES[@]}" -eq 1 ]
  [ "${CGW_CONFLICT_DU_FILES[0]}" = "a.py" ]
  [ "${CGW_CONFLICT_DU_FILES[1]}" = "c.py" ]
  [ "${CGW_CONFLICT_UU_FILES[0]}" = "b.py" ]
}

@test "cgw_classify_conflicts: non-conflict prefixes are ignored" {
  # Returns 1 (no conflicts); || true prevents bats treating return-1 as test failure.
  cgw_classify_conflicts "?? new.py
 M staged.py
M  worktree.py" || true
  [ "${CGW_CONFLICT_TOTAL}" -eq 0 ]
  [ "${#CGW_CONFLICT_DU_FILES[@]}" -eq 0 ]
}

@test "cgw_classify_conflicts: returns 0 (has conflicts) when TOTAL > 0" {
  run cgw_classify_conflicts "UU conflict.py"
  [ "${status}" -eq 0 ]
}

@test "cgw_classify_conflicts: blank lines in input are ignored" {
  cgw_classify_conflicts "DU a.py

UU b.py
"
  [ "${CGW_CONFLICT_TOTAL}" -eq 2 ]
}

@test "cgw_classify_conflicts: second call resets arrays from prior call" {
  cgw_classify_conflicts "DU a.py"
  [ "${CGW_CONFLICT_TOTAL}" -eq 1 ]
  cgw_classify_conflicts "UU b.py"
  [ "${CGW_CONFLICT_TOTAL}" -eq 1 ]
  [ "${#CGW_CONFLICT_DU_FILES[@]}" -eq 0 ]
  [ "${#CGW_CONFLICT_UU_FILES[@]}" -eq 1 ]
}

# ── cgw_validate_commit_message() ─────────────────────────────────────────────

@test "cgw_validate_commit_message accepts all built-in prefixes" {
  for prefix in feat fix docs chore test refactor style perf; do
    run cgw_validate_commit_message "${prefix}: description"
    [ "${status}" -eq 0 ]
  done
}

@test "cgw_validate_commit_message accepts a CGW_EXTRA_PREFIXES custom type" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export CGW_EXTRA_PREFIXES='cuda'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    cgw_validate_commit_message 'cuda: add kernel'
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_validate_commit_message rejects empty message" {
  run cgw_validate_commit_message ""
  [ "${status}" -eq 1 ]
}

@test "cgw_validate_commit_message rejects unprefixed message" {
  run cgw_validate_commit_message "add something without a type"
  [ "${status}" -eq 1 ]
}

@test "cgw_validate_commit_message rejects unknown prefix" {
  run cgw_validate_commit_message "wip: work in progress"
  [ "${status}" -eq 1 ]
}

# ── cgw_resolve_lint_binary() ─────────────────────────────────────────────────

@test "cgw_resolve_lint_binary: returns venv path when binary exists in PYTHON_BIN" {
  local fake_venv
  fake_venv="$(mktemp -d)"
  touch "${fake_venv}/ruff"
  PYTHON_BIN="${fake_venv}" PYTHON_EXT="" run cgw_resolve_lint_binary ruff
  [ "${status}" -eq 0 ]
  [ "${output}" = "${fake_venv}/ruff" ]
  rm -rf "${fake_venv}"
}

@test "cgw_resolve_lint_binary: falls back to system cmd when binary absent from PYTHON_BIN" {
  local fake_venv
  fake_venv="$(mktemp -d)"
  PYTHON_BIN="${fake_venv}" PYTHON_EXT="" run cgw_resolve_lint_binary ruff
  [ "${status}" -eq 0 ]
  [ "${output}" = "ruff" ]
  rm -rf "${fake_venv}"
}

@test "cgw_resolve_lint_binary: respects PYTHON_EXT suffix" {
  local fake_venv
  fake_venv="$(mktemp -d)"
  touch "${fake_venv}/ruff.exe"
  PYTHON_BIN="${fake_venv}" PYTHON_EXT=".exe" run cgw_resolve_lint_binary ruff
  [ "${status}" -eq 0 ]
  [ "${output}" = "${fake_venv}/ruff.exe" ]
  rm -rf "${fake_venv}"
}

# ── cgw_strip_path_arg() ──────────────────────────────────────────────────────

@test "cgw_strip_path_arg: strips trailing token from multi-token string" {
  run cgw_strip_path_arg "check --select E ."
  [ "${status}" -eq 0 ]
  [ "${output}" = "check --select E" ]
}

@test "cgw_strip_path_arg: returns single token unchanged" {
  run cgw_strip_path_arg "check"
  [ "${status}" -eq 0 ]
  [ "${output}" = "check" ]
}

@test "cgw_strip_path_arg: strips trailing path placeholder dot" {
  run cgw_strip_path_arg "format --check ."
  [ "${status}" -eq 0 ]
  [ "${output}" = "format --check" ]
}

# ── cgw_modified_files_for_lint() ─────────────────────────────────────────────

@test "cgw_modified_files_for_lint: returns empty for clean repo" {
  cd "${TEST_REPO_DIR}"
  run cgw_modified_files_for_lint
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "cgw_modified_files_for_lint: lists modified .py file" {
  cd "${TEST_REPO_DIR}"
  echo "print('hello')" > foo.py
  git add foo.py
  git commit -q -m "chore: add foo"
  echo "print('world')" >> foo.py
  run cgw_modified_files_for_lint
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"foo.py"* ]]
}

# ── cgw_run_lint_check() ──────────────────────────────────────────────────────

@test "cgw_run_lint_check: skips when CGW_SKIP_LINT=1" {
  CGW_SKIP_LINT=1 logfile=/dev/null run cgw_run_lint_check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skipped"* ]]
}

@test "cgw_run_lint_check: skips when CGW_LINT_CMD is empty" {
  CGW_LINT_CMD="" logfile=/dev/null run cgw_run_lint_check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skipped"* ]]
}

@test "cgw_run_lint_check: returns 0 when lint binary exits clean" {
  local fake_bin
  fake_bin="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin}"
  chmod +x "${fake_bin}"
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    CGW_LINT_CMD='${fake_bin}'
    CGW_LINT_CHECK_ARGS=''
    CGW_LINT_EXCLUDES=''
    logfile='/dev/null'
    cgw_run_lint_check
  "
  [ "${status}" -eq 0 ]
  rm -f "${fake_bin}"
}

@test "cgw_run_lint_check: returns 1 when lint binary exits with errors" {
  local fake_bin
  fake_bin="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "src/foo.py:1:1: E501 line too long"\nexit 1\n' > "${fake_bin}"
  chmod +x "${fake_bin}"
  CGW_LINT_CMD="${fake_bin}" CGW_LINT_CHECK_ARGS="" CGW_LINT_EXCLUDES="" logfile=/dev/null run cgw_run_lint_check
  [ "${status}" -eq 1 ]
  rm -f "${fake_bin}"
}

# ── cgw_run_format_check() ────────────────────────────────────────────────────

@test "cgw_run_format_check: returns 0 silently when CGW_FORMAT_CMD is empty" {
  CGW_FORMAT_CMD="" logfile=/dev/null run cgw_run_format_check
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "cgw_run_format_check: returns 0 when format binary exits clean" {
  local fake_bin
  fake_bin="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin}"
  chmod +x "${fake_bin}"
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    CGW_FORMAT_CMD='${fake_bin}'
    CGW_FORMAT_CHECK_ARGS=''
    CGW_FORMAT_EXCLUDES=''
    logfile='/dev/null'
    cgw_run_format_check
  "
  [ "${status}" -eq 0 ]
  rm -f "${fake_bin}"
}

@test "cgw_run_format_check: returns 1 when format binary reports failures" {
  local fake_bin
  fake_bin="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "1 file would reformat"\nexit 1\n' > "${fake_bin}"
  chmod +x "${fake_bin}"
  CGW_FORMAT_CMD="${fake_bin}" CGW_FORMAT_CHECK_ARGS="" CGW_FORMAT_EXCLUDES="" logfile=/dev/null run cgw_run_format_check
  [ "${status}" -eq 1 ]
  rm -f "${fake_bin}"
}

# ── cgw_run_lint_fix() ────────────────────────────────────────────────────────

@test "cgw_run_lint_fix: skips when CGW_SKIP_LINT=1" {
  CGW_SKIP_LINT=1 logfile=/dev/null run cgw_run_lint_fix
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skipped"* ]]
}

@test "cgw_run_lint_fix: returns 0 silently when both CMDs are empty" {
  CGW_LINT_CMD="" CGW_FORMAT_CMD="" logfile=/dev/null run cgw_run_lint_fix
  [ "${status}" -eq 0 ]
}

@test "cgw_run_lint_fix: returns 0 when lint binary exits clean" {
  local fake_bin
  fake_bin="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin}"
  chmod +x "${fake_bin}"
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    CGW_LINT_CMD='${fake_bin}'
    CGW_FORMAT_CMD=''
    CGW_LINT_FIX_ARGS=''
    CGW_LINT_EXCLUDES=''
    logfile='/dev/null'
    cgw_run_lint_fix
  "
  [ "${status}" -eq 0 ]
  rm -f "${fake_bin}"
}

@test "cgw_run_lint_fix: returns 1 when lint binary exits with errors" {
  local fake_bin
  fake_bin="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 1\n' > "${fake_bin}"
  chmod +x "${fake_bin}"
  CGW_LINT_CMD="${fake_bin}" CGW_FORMAT_CMD="" CGW_LINT_FIX_ARGS="" CGW_LINT_EXCLUDES="" logfile=/dev/null run cgw_run_lint_fix
  [ "${status}" -eq 1 ]
  rm -f "${fake_bin}"
}

# ── cgw_run_markdownlint_check() ──────────────────────────────────────────────

@test "cgw_run_markdownlint_check: skips when CGW_SKIP_MD_LINT=1" {
  CGW_SKIP_MD_LINT=1 logfile=/dev/null run cgw_run_markdownlint_check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skipped"* ]]
}

@test "cgw_run_markdownlint_check: returns 0 silently when CGW_MARKDOWNLINT_CMD is empty" {
  CGW_MARKDOWNLINT_CMD="" logfile=/dev/null run cgw_run_markdownlint_check
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "cgw_run_markdownlint_check: returns 0 when markdownlint exits clean" {
  local fake_bin
  fake_bin="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin}"
  chmod +x "${fake_bin}"
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    CGW_MARKDOWNLINT_CMD='${fake_bin}'
    CGW_MARKDOWNLINT_ARGS=''
    logfile='/dev/null'
    cgw_run_markdownlint_check
  "
  [ "${status}" -eq 0 ]
  rm -f "${fake_bin}"
}

@test "cgw_run_markdownlint_check: returns 1 when markdownlint finds errors" {
  local fake_bin
  fake_bin="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "README.md:5 MD013 line too long"\nexit 1\n' > "${fake_bin}"
  chmod +x "${fake_bin}"
  CGW_MARKDOWNLINT_CMD="${fake_bin}" CGW_MARKDOWNLINT_ARGS="" logfile=/dev/null run cgw_run_markdownlint_check
  [ "${status}" -eq 1 ]
  rm -f "${fake_bin}"
}

# ── cgw_confirm() ─────────────────────────────────────────────────────────────

@test "cgw_confirm: 'yes' returns 0" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'yes' | cgw_confirm 'Continue?'
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_confirm: 'no' returns 1" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'no' | cgw_confirm 'Continue?'
  "
  [ "${status}" -eq 1 ]
}

@test "cgw_confirm: 'y' returns 0 (abbreviated yes)" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'y' | cgw_confirm 'Continue?'
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_confirm: 'Y' returns 0 (uppercase abbreviated yes)" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'Y' | cgw_confirm 'Continue?'
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_confirm: 'YES' returns 0 (uppercase yes)" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'YES' | cgw_confirm 'Continue?'
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_confirm: 'Yes' returns 0 (mixed-case yes)" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'Yes' | cgw_confirm 'Continue?'
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_confirm: 'n' returns 1 (abbreviated no)" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'n' | cgw_confirm 'Continue?'
  "
  [ "${status}" -eq 1 ]
}

@test "cgw_confirm: 'N' returns 1 (uppercase abbreviated no)" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'N' | cgw_confirm 'Continue?'
  "
  [ "${status}" -eq 1 ]
}

@test "cgw_confirm: 'NO' returns 1 (uppercase no)" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'NO' | cgw_confirm 'Continue?'
  "
  [ "${status}" -eq 1 ]
}

@test "cgw_confirm: unknown input with --default yes returns 0 (falls back to default)" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'maybe' | cgw_confirm 'Continue?' --default yes
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_confirm: unknown input with --default no returns 1 (falls back to default)" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'maybe' | cgw_confirm 'Continue?' --default no
  "
  [ "${status}" -eq 1 ]
}

@test "cgw_confirm: --default yes empty input returns 0" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo '' | cgw_confirm 'Continue?' --default yes
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_confirm: --default no empty input returns 1" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo '' | cgw_confirm 'Continue?' --default no
  "
  [ "${status}" -eq 1 ]
}

@test "cgw_confirm: --literal-token FORCE with matching token returns 0" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'FORCE' | cgw_confirm \"Type 'FORCE' to confirm\" --literal-token FORCE
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_confirm: --literal-token FORCE with wrong case returns 1" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    echo 'force' | cgw_confirm \"Type 'FORCE' to confirm\" --literal-token FORCE
  "
  [ "${status}" -eq 1 ]
}

@test "cgw_confirm: CGW_NON_INTERACTIVE=1 with abort policy exits 1" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    CGW_NON_INTERACTIVE=1 cgw_confirm 'Continue?' --non-interactive abort
  "
  [ "${status}" -eq 1 ]
}

@test "cgw_confirm: CGW_NON_INTERACTIVE=1 with accept policy returns 0" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    CGW_NON_INTERACTIVE=1 cgw_confirm 'Continue?' --non-interactive accept
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_confirm: CGW_NON_INTERACTIVE=1 with deny policy returns 1" {
  run bash -c "
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    CGW_NON_INTERACTIVE=1 cgw_confirm 'Continue?' --non-interactive deny
  " 2>/dev/null
  [ "${status}" -eq 1 ]
}

# ── cgw_rev_count() ────────────────────────────────────────────────────────────
# Each test spins up its own throwaway repo so results are independent of
# commits accumulated by earlier tests in the shared file-scope repo.

@test "cgw_rev_count: tip 1 ahead of base returns 1" {
  run bash -c "
    tmp=\$(mktemp -d)
    git init --quiet \"\${tmp}\"
    git -C \"\${tmp}\" config core.autocrlf false
    git -C \"\${tmp}\" config user.email t@t.com
    git -C \"\${tmp}\" config user.name T
    echo x > \"\${tmp}/f\" && git -C \"\${tmp}\" add f
    git -C \"\${tmp}\" commit --quiet -m 'init'
    git -C \"\${tmp}\" checkout --quiet -b main 2>/dev/null || \
      git -C \"\${tmp}\" branch -m main 2>/dev/null || true
    git -C \"\${tmp}\" checkout --quiet -b dev
    echo y >> \"\${tmp}/f\" && git -C \"\${tmp}\" add f
    git -C \"\${tmp}\" commit --quiet -m 'dev'
    cd \"\${tmp}\"
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    out=\$(cgw_rev_count main dev); ec=\$?
    rm -rf \"\${tmp}\"
    echo \"\${out}\"; exit \${ec}
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "1" ]
}

@test "cgw_rev_count: base not ahead of tip returns 0" {
  run bash -c "
    tmp=\$(mktemp -d)
    git init --quiet \"\${tmp}\"
    git -C \"\${tmp}\" config core.autocrlf false
    git -C \"\${tmp}\" config user.email t@t.com
    git -C \"\${tmp}\" config user.name T
    echo x > \"\${tmp}/f\" && git -C \"\${tmp}\" add f
    git -C \"\${tmp}\" commit --quiet -m 'init'
    git -C \"\${tmp}\" checkout --quiet -b main 2>/dev/null || \
      git -C \"\${tmp}\" branch -m main 2>/dev/null || true
    git -C \"\${tmp}\" checkout --quiet -b dev
    echo y >> \"\${tmp}/f\" && git -C \"\${tmp}\" add f
    git -C \"\${tmp}\" commit --quiet -m 'dev'
    cd \"\${tmp}\"
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    out=\$(cgw_rev_count dev main); ec=\$?
    rm -rf \"\${tmp}\"
    echo \"\${out}\"; exit \${ec}
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "0" ]
}

@test "cgw_rev_count: same ref returns 0" {
  run bash -c "
    tmp=\$(mktemp -d)
    git init --quiet \"\${tmp}\"
    git -C \"\${tmp}\" config core.autocrlf false
    git -C \"\${tmp}\" config user.email t@t.com
    git -C \"\${tmp}\" config user.name T
    echo x > \"\${tmp}/f\" && git -C \"\${tmp}\" add f
    git -C \"\${tmp}\" commit --quiet -m 'init'
    git -C \"\${tmp}\" checkout --quiet -b main 2>/dev/null || \
      git -C \"\${tmp}\" branch -m main 2>/dev/null || true
    cd \"\${tmp}\"
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    out=\$(cgw_rev_count main main); ec=\$?
    rm -rf \"\${tmp}\"
    echo \"\${out}\"; exit \${ec}
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "0" ]
}

@test "cgw_rev_count: bad base ref exits non-zero" {
  run bash -c "
    tmp=\$(mktemp -d)
    git init --quiet \"\${tmp}\"
    git -C \"\${tmp}\" config core.autocrlf false
    git -C \"\${tmp}\" config user.email t@t.com
    git -C \"\${tmp}\" config user.name T
    echo x > \"\${tmp}/f\" && git -C \"\${tmp}\" add f
    git -C \"\${tmp}\" commit --quiet -m 'init'
    cd \"\${tmp}\"
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    cgw_rev_count nonexistent HEAD 2>/dev/null; ec=\$?
    rm -rf \"\${tmp}\"; exit \${ec}
  "
  [ "${status}" -ne 0 ]
}

@test "cgw_rev_count: bad tip ref exits non-zero" {
  run bash -c "
    tmp=\$(mktemp -d)
    git init --quiet \"\${tmp}\"
    git -C \"\${tmp}\" config core.autocrlf false
    git -C \"\${tmp}\" config user.email t@t.com
    git -C \"\${tmp}\" config user.name T
    echo x > \"\${tmp}/f\" && git -C \"\${tmp}\" add f
    git -C \"\${tmp}\" commit --quiet -m 'init'
    cd \"\${tmp}\"
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    cgw_rev_count HEAD nonexistent 2>/dev/null; ec=\$?
    rm -rf \"\${tmp}\"; exit \${ec}
  "
  [ "${status}" -ne 0 ]
}

# ── cgw_remote_reachable() and cgw_remote_branch_exists() ─────────────────────

@test "cgw_remote_reachable: reachable remote returns 0" {
  run bash -c "
    tmp=\$(mktemp -d)
    bare=\"\${tmp}/remote.git\"
    repo=\"\${tmp}/repo\"
    git init --bare --quiet \"\${bare}\"
    git init --quiet \"\${repo}\"
    git -C \"\${repo}\" config user.email t@t.com
    git -C \"\${repo}\" config user.name T
    echo x > \"\${repo}/f\"
    git -C \"\${repo}\" add f
    git -C \"\${repo}\" commit --quiet -m 'init'
    git -C \"\${repo}\" remote add origin \"\${bare}\"
    git -C \"\${repo}\" push --quiet origin HEAD:main
    cd \"\${repo}\"
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    cgw_remote_reachable origin; ec=\$?
    rm -rf \"\${tmp}\"
    exit \${ec}
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_remote_reachable: unknown remote exits non-zero" {
  run cgw_remote_reachable "no-such-remote"
  [ "${status}" -ne 0 ]
}

@test "cgw_remote_branch_exists: existing branch returns 0" {
  run bash -c "
    tmp=\$(mktemp -d)
    bare=\"\${tmp}/remote.git\"
    repo=\"\${tmp}/repo\"
    git init --bare --quiet \"\${bare}\"
    git init --quiet \"\${repo}\"
    git -C \"\${repo}\" config user.email t@t.com
    git -C \"\${repo}\" config user.name T
    echo x > \"\${repo}/f\"
    git -C \"\${repo}\" add f
    git -C \"\${repo}\" commit --quiet -m 'init'
    git -C \"\${repo}\" remote add origin \"\${bare}\"
    git -C \"\${repo}\" push --quiet origin HEAD:main
    cd \"\${repo}\"
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    cgw_remote_branch_exists origin main; ec=\$?
    rm -rf \"\${tmp}\"
    exit \${ec}
  "
  [ "${status}" -eq 0 ]
}

@test "cgw_remote_branch_exists: missing branch exits non-zero" {
  run bash -c "
    tmp=\$(mktemp -d)
    bare=\"\${tmp}/remote.git\"
    repo=\"\${tmp}/repo\"
    git init --bare --quiet \"\${bare}\"
    git init --quiet \"\${repo}\"
    git -C \"\${repo}\" config user.email t@t.com
    git -C \"\${repo}\" config user.name T
    echo x > \"\${repo}/f\"
    git -C \"\${repo}\" add f
    git -C \"\${repo}\" commit --quiet -m 'init'
    git -C \"\${repo}\" remote add origin \"\${bare}\"
    git -C \"\${repo}\" push --quiet origin HEAD:main
    cd \"\${repo}\"
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_common.sh'
    cgw_remote_branch_exists origin nonexistent-branch; ec=\$?
    rm -rf \"\${tmp}\"
    exit \${ec}
  "
  [ "${status}" -ne 0 ]
}
