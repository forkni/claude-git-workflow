#!/usr/bin/env bats
# tests/unit/net_timeout.bats - Unit tests for cgw_net_git (CGW_NET_TIMEOUT)
# Runs: bats tests/unit/net_timeout.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo
  setup_mock_bin
  export SCRIPT_DIR="${CGW_PROJECT_ROOT}/scripts/git"
  # shellcheck source=scripts/git/_common.sh
  source "${CGW_PROJECT_ROOT}/scripts/git/_common.sh"
  export PROJECT_ROOT="${TEST_REPO_DIR}"
  cd "${TEST_REPO_DIR}"
  REAL_GIT="$(command -v git)"
  TIMEOUT_LOG="${TEST_TMPDIR}/timeout.log"
  unset GIT_TERMINAL_PROMPT CGW_NET_TIMEOUT
  export CGW_NON_INTERACTIVE=0
}

teardown() {
  cleanup_test_repo
}

# _install_hung_git -- a `git` whose network subcommands never return; anything
# else goes to the real git. `exec sleep` keeps the hung process a single
# process, so the timeout's kill also releases bats' output pipe.
_install_hung_git() {
  cat >"${MOCK_BIN_DIR}/git" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  fetch | push | pull | ls-remote | clone | remote) exec sleep 60 ;;
esac
exec "${REAL_GIT}" "\$@"
EOF
  chmod +x "${MOCK_BIN_DIR}/git"
}

# _install_echo_git -- a `git` that reports what it saw instead of doing anything.
_install_echo_git() {
  cat >"${MOCK_BIN_DIR}/git" <<'EOF'
#!/usr/bin/env bash
echo "plain-git args=$* prompt=${GIT_TERMINAL_PROMPT-unset}"
EOF
  chmod +x "${MOCK_BIN_DIR}/git"
}

# _install_gnu_timeout_stub -- a `timeout` that identifies as GNU coreutils,
# logs the options it was given and runs the command without any limit.
_install_gnu_timeout_stub() {
  cat >"${MOCK_BIN_DIR}/timeout" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  echo "timeout (GNU coreutils) 9.9"
  exit 0
fi
echo "\$*" >>"${TIMEOUT_LOG}"
while [[ "\${1:-}" == --* ]]; do shift; done
shift
exec "\$@"
EOF
  chmod +x "${MOCK_BIN_DIR}/timeout"
}

# _install_windows_timeout_stub -- C:\Windows\System32\timeout.exe: rejects
# --version, and would sleep instead of wrapping a command.
_install_windows_timeout_stub() {
  cat >"${MOCK_BIN_DIR}/timeout" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  echo "ERROR: Invalid syntax. Default option is not allowed more than '1' time(s)." >&2
  exit 1
fi
echo "\$*" >>"${TIMEOUT_LOG}"
exit 99
EOF
  chmod +x "${MOCK_BIN_DIR}/timeout"
}

# ── pass-through ──────────────────────────────────────────────────────────────

@test "cgw_net_git: success passes output and status through" {
  run cgw_net_git --version
  [ "${status}" -eq 0 ]
  [[ "${output}" == "git version "* ]]
}

@test "cgw_net_git: a failing git keeps its own exit code and stderr" {
  run cgw_net_git rev-parse --verify --quiet refs/heads/does-not-exist
  [ "${status}" -eq 1 ]
  run cgw_net_git fetch no-such-remote
  [ "${status}" -ne 0 ]
  [ "${status}" -ne 124 ]
  [[ "${output}" != *"timed out"* ]]
}

@test "cgw_net_git: arguments with spaces reach git intact" {
  _install_echo_git
  run cgw_net_git fetch "a b" c
  [[ "${output}" == "plain-git args=fetch a b c prompt=unset" ]]
}

@test "cgw_net_git: stdin reaches git" {
  local want got
  want="$(printf 'hello\n' | git hash-object --stdin)"
  got="$(printf 'hello\n' | cgw_net_git hash-object --stdin)"
  [ -n "${want}" ]
  [ "${got}" = "${want}" ]
}

# ── the timeout itself ────────────────────────────────────────────────────────

@test "cgw_net_git: a hung git returns 124 with a message naming op, limit and knob" {
  command -v timeout >/dev/null 2>&1 || skip "no timeout on PATH"
  _cgw_gnu_timeout_available || skip "timeout on PATH is not GNU coreutils"
  _install_hung_git
  export CGW_NET_TIMEOUT=1
  run cgw_net_git fetch origin
  [ "${status}" -eq 124 ]
  [[ "${output}" == *"[ERROR] git fetch timed out after 1s"* ]]
  [[ "${output}" == *"CGW_NET_TIMEOUT"* ]]
}

@test "cgw_net_git: the timeout also applies in non-interactive mode" {
  _cgw_gnu_timeout_available || skip "timeout on PATH is not GNU coreutils"
  _install_hung_git
  export CGW_NET_TIMEOUT=1 CGW_NON_INTERACTIVE=1
  run cgw_net_git push origin main
  [ "${status}" -eq 124 ]
  [[ "${output}" == *"git push timed out after 1s"* ]]
}

@test "cgw_net_git: CGW_NET_TIMEOUT=0 disables the limit and runs plain git" {
  _install_gnu_timeout_stub
  cat >"${MOCK_BIN_DIR}/git" <<'EOF'
#!/usr/bin/env bash
sleep 2
echo "slow-but-fine"
exit 7
EOF
  chmod +x "${MOCK_BIN_DIR}/git"
  export CGW_NET_TIMEOUT=0
  run cgw_net_git fetch origin
  [ "${status}" -eq 7 ]
  [[ "${output}" == "slow-but-fine" ]]
  [ ! -e "${TIMEOUT_LOG}" ]
}

@test "cgw_net_git: a 124 from git itself is not reported as a timeout when unwrapped" {
  cat >"${MOCK_BIN_DIR}/git" <<'EOF'
#!/usr/bin/env bash
exit 124
EOF
  chmod +x "${MOCK_BIN_DIR}/git"
  export CGW_NET_TIMEOUT=0
  run cgw_net_git fetch origin
  [ "${status}" -eq 124 ]
  [[ "${output}" != *"timed out"* ]]
}

@test "cgw_net_git: default limit is 120s and a non-numeric value falls back to it" {
  _install_gnu_timeout_stub
  _install_echo_git
  run cgw_net_git fetch origin
  [ "${status}" -eq 0 ]
  grep -q -- "120s" "${TIMEOUT_LOG}"
  : >"${TIMEOUT_LOG}"
  export CGW_NET_TIMEOUT=soon
  run cgw_net_git fetch origin
  grep -q -- "120s" "${TIMEOUT_LOG}"
  : >"${TIMEOUT_LOG}"
  export CGW_NET_TIMEOUT=45
  run cgw_net_git fetch origin
  grep -q -- "45s" "${TIMEOUT_LOG}"
}

# ── GNU vs Windows timeout ────────────────────────────────────────────────────

@test "cgw_net_git: a non-GNU timeout (Windows timeout.exe) is not used" {
  _install_windows_timeout_stub
  _install_echo_git
  export CGW_NET_TIMEOUT=5
  run cgw_net_git fetch origin
  [ "${status}" -eq 0 ]
  [[ "${output}" == "plain-git args=fetch origin prompt=unset" ]]
  [ ! -e "${TIMEOUT_LOG}" ]
}

@test "cgw_net_git: no timeout on PATH at all runs plain git" {
  # A PATH holding only a builtin-only mock git: nothing named timeout anywhere.
  local bare="${TEST_TMPDIR}/bare-bin"
  mkdir -p "${bare}"
  printf '%s\n' '#!/bin/bash' 'echo "plain-git args=$*"' >"${bare}/git"
  chmod +x "${bare}/git"
  export CGW_NET_TIMEOUT=5
  local saved_path="${PATH}" rc=0 got
  PATH="${bare}"
  got="$(cgw_net_git fetch origin)" || rc=$?
  PATH="${saved_path}"
  [ "${rc}" -eq 0 ]
  [ "${got}" = "plain-git args=fetch origin" ]
}

@test "_cgw_gnu_timeout_available: re-probes when the timeout on PATH changes" {
  local rc=0
  _install_windows_timeout_stub
  _cgw_gnu_timeout_available || rc=$?
  [ "${rc}" -ne 0 ]
  _install_gnu_timeout_stub
  # A different file at the same path is not seen; a different path is.
  mkdir -p "${TEST_TMPDIR}/gnu-bin"
  cp "${MOCK_BIN_DIR}/timeout" "${TEST_TMPDIR}/gnu-bin/timeout"
  PATH="${TEST_TMPDIR}/gnu-bin:${PATH}"
  hash -r
  _cgw_gnu_timeout_available
}

# ── interactive vs non-interactive ────────────────────────────────────────────

@test "cgw_net_git: GIT_TERMINAL_PROMPT=0 is set only when non-interactive" {
  _install_echo_git
  export CGW_NET_TIMEOUT=0
  CGW_NON_INTERACTIVE=1 run cgw_net_git fetch origin
  [[ "${output}" == *"prompt=0" ]]
  CGW_NON_INTERACTIVE=0 run cgw_net_git fetch origin
  [[ "${output}" == *"prompt=unset" ]]
}

@test "cgw_net_git: an explicit GIT_TERMINAL_PROMPT survives non-interactive mode" {
  _install_echo_git
  export CGW_NET_TIMEOUT=0
  CGW_NON_INTERACTIVE=1 GIT_TERMINAL_PROMPT=1 run cgw_net_git fetch origin
  [[ "${output}" == *"prompt=1" ]]
}

@test "cgw_net_git: GIT_TERMINAL_PROMPT does not leak into the caller's environment" {
  _install_echo_git
  export CGW_NET_TIMEOUT=0 CGW_NON_INTERACTIVE=1
  cgw_net_git fetch origin >/dev/null
  [ -z "${GIT_TERMINAL_PROMPT+x}" ]
}

@test "cgw_net_git: interactive runs keep the terminal (--foreground), non-interactive runs do not" {
  _install_gnu_timeout_stub
  _install_echo_git
  export CGW_NET_TIMEOUT=30
  CGW_NON_INTERACTIVE=0 run cgw_net_git fetch origin
  grep -q -- "--foreground 30s" "${TIMEOUT_LOG}"
  : >"${TIMEOUT_LOG}"
  CGW_NON_INTERACTIVE=1 run cgw_net_git fetch origin
  run grep -c -- "--foreground" "${TIMEOUT_LOG}"
  [ "${output}" = "0" ]
  grep -q -- "^30s " "${TIMEOUT_LOG}"
}

# ── silent probes and run_git_with_logging ────────────────────────────────────

@test "cgw_remote_reachable: a hung remote returns 124 and still names the timeout" {
  _cgw_gnu_timeout_available || skip "timeout on PATH is not GNU coreutils"
  _install_hung_git
  export CGW_NET_TIMEOUT=1
  run cgw_remote_reachable origin
  [ "${status}" -eq 124 ]
  [[ "${output}" == *"git ls-remote timed out after 1s"* ]]
}

@test "cgw_remote_branch_exists: a hung remote returns 124, not 'absent' (2)" {
  _cgw_gnu_timeout_available || skip "timeout on PATH is not GNU coreutils"
  _install_hung_git
  export CGW_NET_TIMEOUT=1
  run cgw_remote_branch_exists origin main
  [ "${status}" -eq 124 ]
  [[ "${output}" == *"CGW_NET_TIMEOUT"* ]]
}

@test "cgw_remote_reachable: a reachable remote still returns 0 and prints nothing" {
  git init --bare --quiet "${TEST_TMPDIR}/remote.git"
  run cgw_remote_reachable "${TEST_TMPDIR}/remote.git"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "run_git_with_logging: a hung push is reported as exit 124 with the timeout message" {
  _cgw_gnu_timeout_available || skip "timeout on PATH is not GNU coreutils"
  _install_hung_git
  export CGW_NET_TIMEOUT=1
  local lf="${TEST_TMPDIR}/rgwl.log"
  : >"${lf}"
  run_git_with_logging "GIT PUSH" "${lf}" push origin main >/dev/null 2>&1 || true
  [ "${GIT_EXIT_CODE}" -eq 124 ]
  [[ "${GIT_OUTPUT}" == *"git push timed out after 1s"* ]]
}

@test "run_git_with_logging: a non-network subcommand is not wrapped" {
  _install_gnu_timeout_stub
  export CGW_NET_TIMEOUT=30
  local lf="${TEST_TMPDIR}/rgwl.log"
  : >"${lf}"
  run_git_with_logging "STATUS" "${lf}" status --short >/dev/null 2>&1
  [ "${GIT_EXIT_CODE}" -eq 0 ]
  [ ! -e "${TIMEOUT_LOG}" ]
}
