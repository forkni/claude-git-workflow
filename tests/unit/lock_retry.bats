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

@test "cgw_run_with_lock_retry: exhausts retries and returns exit code when lock persists" {
  local mock_cmd="${TEST_TMPDIR}/persistent_lock.sh"
  cat << EOF > "${mock_cmd}"
#!/usr/bin/env bash
echo "fatal: Unable to create '${TEST_REPO_DIR}/.git/index.lock': File exists." >&2
exit 128
EOF
  chmod +x "${mock_cmd}"

  CGW_LOCK_RETRY_ATTEMPTS=3 CGW_LOCK_RETRY_DELAY=0 run cgw_run_with_lock_retry "${mock_cmd}"
  [ "${status}" -eq 128 ]
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
