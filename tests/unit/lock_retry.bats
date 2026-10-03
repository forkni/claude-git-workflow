#!/usr/bin/env bats
# tests/unit/lock_retry.bats - Unit tests for cgw_run_with_lock_retry
# Runs: bats tests/unit/lock_retry.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
  # shellcheck source=scripts/git/_common.sh
  source "${CGW_PROJECT_ROOT}/scripts/git/_common.sh"
  export PROJECT_ROOT="${TEST_REPO_DIR}"
  cd "${TEST_REPO_DIR}"
}

teardown() {
  cleanup_test_repo
}

# ── cgw_run_with_lock_retry() ─────────────────────────────────────────────────

@test "cgw_run_with_lock_retry: succeeds on first try with normal command" {
  run cgw_run_with_lock_retry git status
  [ "${status}" -eq 0 ]
}

@test "cgw_run_with_lock_retry: preserves multi-word arguments with spaces" {
  echo "content" > file.txt
  git add file.txt
  run cgw_run_with_lock_retry git commit -m "feat: message with spaces and special (chars)"
  [ "${status}" -eq 0 ]
  run git log -1 --format='%s'
  [ "${output}" = "feat: message with spaces and special (chars)" ]
}

@test "cgw_run_with_lock_retry: fails immediately on non-lock error without retrying" {
  # git checkout of nonexistent branch fails with non-lock error
  local attempts_seen=0
  run cgw_run_with_lock_retry git checkout non-existent-branch-12345
  [ "${status}" -ne 0 ]
  # Output must contain git's error message
  [[ "${output}" == *"did not match any file"* ]] || [[ "${output}" == *"error"* ]]
  # Must NOT log index lock retry
  [[ "${output}" != *"[cgw-lock] Index lock collision"* ]]
}

@test "cgw_run_with_lock_retry: retries and succeeds when lock collision is transient" {
  # Create a wrapper command that fails with index.lock error on attempt 1, succeeds on attempt 2
  local state_file="${TEST_TMPDIR}/attempt_counter.txt"
  echo "0" > "${state_file}"

  local mock_cmd="${TEST_TMPDIR}/flake_git.sh"
  cat << EOF > "${mock_cmd}"
#!/usr/bin/env bash
count=\$(cat "${state_file}")
count=\$((count + 1))
echo "\${count}" > "${state_file}"
if [[ \${count} -eq 1 ]]; then
  echo "fatal: Unable to create '${TEST_REPO_DIR}/.git/index.lock': File exists." >&2
  exit 128
fi
echo "Mock git command succeeded"
exit 0
EOF
  chmod +x "${mock_cmd}"

  CGW_LOCK_RETRY_ATTEMPTS=3 CGW_LOCK_RETRY_DELAY=0 run cgw_run_with_lock_retry "${mock_cmd}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[cgw-lock] Index lock collision"* ]]
  [[ "${output}" == *"(attempt 1/3)"* ]]
  [[ "${output}" == *"Mock git command succeeded"* ]]
  final_count=$(cat "${state_file}")
  [ "${final_count}" -eq 2 ]
}

@test "cgw_run_with_lock_retry: exhausts retries and returns CGW_RC_INDEX_LOCKED when lock persists" {
  local mock_cmd="${TEST_TMPDIR}/persistent_lock.sh"
  cat << EOF > "${mock_cmd}"
#!/usr/bin/env bash
echo "fatal: Unable to create '${TEST_REPO_DIR}/.git/index.lock': File exists." >&2
exit 128
EOF
  chmod +x "${mock_cmd}"

  CGW_LOCK_RETRY_ATTEMPTS=3 CGW_LOCK_RETRY_DELAY=0 run cgw_run_with_lock_retry "${mock_cmd}"
  [ "${status}" -eq 75 ]
  [[ "${output}" == *"(attempt 1/3)"* ]]
  [[ "${output}" == *"(attempt 2/3)"* ]]
  [[ "${output}" == *"fatal: Unable to create"* ]]
}

@test "cgw_run_with_lock_retry: preserves stderr output when command succeeds" {
  local mock_cmd="${TEST_TMPDIR}/stderr_warn.sh"
  cat << EOF > "${mock_cmd}"
#!/usr/bin/env bash
echo "advisory warning from pre-commit hook" >&2
exit 0
EOF
  chmod +x "${mock_cmd}"

  run cgw_run_with_lock_retry "${mock_cmd}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"advisory warning from pre-commit hook"* ]]
}

# ── stderr streaming (code-review follow-up) ──────────────────────────────────

@test "cgw_run_with_lock_retry: streams stderr live instead of after the command exits" {
  local release="${TEST_TMPDIR}/release"
  local seen="${TEST_TMPDIR}/seen.txt"
  local mock_cmd="${TEST_TMPDIR}/slow_hook.sh"
  cat << EOF > "${mock_cmd}"
#!/usr/bin/env bash
echo "early hook output" >&2
for _ in \$(seq 1 100); do
  [[ -e "${release}" ]] && exit 0
  sleep 0.1
done
exit 1
EOF
  chmod +x "${mock_cmd}"

  cgw_run_with_lock_retry "${mock_cmd}" 2>"${seen}" &
  local pid=$!
  local streamed=0 i
  for i in $(seq 1 40); do
    if grep -q "early hook output" "${seen}" 2>/dev/null; then
      streamed=1
      break
    fi
    sleep 0.1
  done
  : >"${release}"
  wait "${pid}"
  [ "${streamed}" -eq 1 ]
}

@test "cgw_run_with_lock_retry: keeps stdout and stderr separate" {
  local mock_cmd="${TEST_TMPDIR}/both.sh"
  cat << 'EOF' > "${mock_cmd}"
#!/usr/bin/env bash
echo "to-stdout"
echo "to-stderr" >&2
exit 0
EOF
  chmod +x "${mock_cmd}"

  run --separate-stderr cgw_run_with_lock_retry "${mock_cmd}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "to-stdout" ]
  [ "${stderr}" = "to-stderr" ]
}

@test "cgw_run_with_lock_retry: prints an unrelated failure's stderr exactly once" {
  local mock_cmd="${TEST_TMPDIR}/fail_once.sh"
  cat << 'EOF' > "${mock_cmd}"
#!/usr/bin/env bash
echo "hook rejected the commit" >&2
exit 3
EOF
  chmod +x "${mock_cmd}"

  run cgw_run_with_lock_retry "${mock_cmd}"
  [ "${status}" -eq 3 ]
  local count
  count="$(printf '%s\n' "${output}" | grep -c "hook rejected the commit")"
  [ "${count}" -eq 1 ]
}

# ── ensure_no_stale_index_lock: active operation is refused immediately ───────

@test "ensure_no_stale_index_lock: paused merge + fresh lock that clears is waited out, not refused" {
  local git_dir
  git_dir="$(git -C "${TEST_REPO_DIR}" rev-parse --absolute-git-dir)"
  : >"${git_dir}/index.lock"
  git -C "${TEST_REPO_DIR}" rev-parse HEAD >"${git_dir}/MERGE_HEAD"
  ( sleep 1 && rm -f "${git_dir}/index.lock" ) &
  local bg_pid=$!

  CGW_INDEX_LOCK_WAIT_SECONDS=8 run ensure_no_stale_index_lock
  wait "${bg_pid}" 2>/dev/null || true

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"waiting up to"* ]]
  [[ "${output}" != *"REFUSED"* ]]
}

@test "ensure_no_stale_index_lock: paused merge + stale lock is still refused with the real reason" {
  local git_dir
  git_dir="$(git -C "${TEST_REPO_DIR}" rev-parse --absolute-git-dir)"
  : >"${git_dir}/index.lock"
  touch -d "120 seconds ago" "${git_dir}/index.lock"
  git -C "${TEST_REPO_DIR}" rev-parse HEAD >"${git_dir}/MERGE_HEAD"

  CGW_INDEX_LOCK_WAIT_SECONDS=8 run ensure_no_stale_index_lock

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"git operation in progress (MERGE_HEAD)"* ]]
  [ -f "${git_dir}/index.lock" ]
}

# ── lock refusal is distinguishable from a git failure ────────────────────────

@test "cgw_run_with_lock_retry: a refused lock returns CGW_RC_INDEX_LOCKED and never runs the command" {
  local git_dir marker="${TEST_TMPDIR}/ran"
  git_dir="$(git -C "${TEST_REPO_DIR}" rev-parse --absolute-git-dir)"
  : >"${git_dir}/index.lock"
  touch -d "120 seconds ago" "${git_dir}/index.lock"

  CGW_AUTO_REMOVE_INDEX_LOCK=0 run cgw_run_with_lock_retry touch "${marker}"
  [ "${status}" -eq "${CGW_RC_INDEX_LOCKED}" ]
  [ ! -e "${marker}" ]
}

@test "run_git_with_logging: a refused lock sets GIT_EXIT_CODE to CGW_RC_INDEX_LOCKED" {
  local git_dir
  git_dir="$(git -C "${TEST_REPO_DIR}" rev-parse --absolute-git-dir)"
  : >"${git_dir}/index.lock"
  touch -d "120 seconds ago" "${git_dir}/index.lock"

  local rc=0
  CGW_AUTO_REMOVE_INDEX_LOCK=0 run_git_with_logging "LOCKED" "${TEST_TMPDIR}/l.log" status >/dev/null 2>&1 || rc=$?
  [ "${rc}" -eq "${CGW_RC_INDEX_LOCKED}" ]
  [ "${GIT_EXIT_CODE}" -eq "${CGW_RC_INDEX_LOCKED}" ]
}
