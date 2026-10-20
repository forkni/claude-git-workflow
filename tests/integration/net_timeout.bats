#!/usr/bin/env bats
# tests/integration/net_timeout.bats - CGW scripts report a hung remote instead of hanging
# Runs: bats tests/integration/net_timeout.bats
#
# A `git` shim on PATH never returns for the network subcommands named in
# $HUNG_SUBCMDS and delegates everything else to the real git, so each script
# runs for real up to the point where it talks to the "remote".

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

setup() {
  create_test_repo_with_remote
  setup_mock_bin
  install_mock_lint
  git -C "${TEST_REPO_DIR}" checkout --quiet development
  # The scripts under test source _common.sh, which probes `timeout`; skip the
  # whole file where the timeout on PATH is not GNU's (nothing to test there).
  local banner
  banner="$(timeout --version 2>/dev/null | head -n 1)" || banner=""
  [[ "${banner}" == *"GNU coreutils"* ]] || skip "timeout on PATH is not GNU coreutils"
  export CGW_NET_TIMEOUT=1
}

teardown() {
  cleanup_test_repo
}

# _hang <subcommand...> -- the shim hangs on these, delegates the rest. `exec sleep`
# keeps the hung process a single process, so the timeout's kill frees bats' pipe.
_hang() {
  local real_git pattern
  real_git="$(command -v git)"
  pattern="$(printf '%s | ' "$@")"
  pattern="${pattern% | }"
  cat >"${MOCK_BIN_DIR}/git" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  ${pattern}) exec sleep 60 ;;
esac
exec "${real_git}" "\$@"
EOF
  chmod +x "${MOCK_BIN_DIR}/git"
}

_run_push() {
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

@test "push_validated: an unreachable remote that hangs is reported as a timeout, not a hang" {
  _hang ls-remote
  local started=$SECONDS
  run _run_push "--skip-lint"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"git ls-remote timed out after 1s"* ]]
  [[ "${output}" == *"CGW_NET_TIMEOUT"* ]]
  [[ "${output}" == *"not reachable"* ]]
  ((SECONDS - started < 30))
}

@test "push_validated: a push that hangs after the checks passed fails with the timeout named" {
  echo "new" >"${TEST_REPO_DIR}/new.txt"
  git -C "${TEST_REPO_DIR}" add new.txt
  git -C "${TEST_REPO_DIR}" commit --quiet -m "feat: new file"
  _hang push
  run _run_push "--skip-lint"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"git push timed out after 1s"* ]]
  [[ "${output}" == *"Push failed"* ]]
  # nothing reached the remote
  local remote_tip local_tip
  remote_tip="$(git -C "${TEST_REMOTE_DIR}" rev-parse --verify --quiet refs/heads/development || true)"
  local_tip="$(git -C "${TEST_REPO_DIR}" rev-parse HEAD)"
  [ "${remote_tip}" != "${local_tip}" ]
}

@test "push_validated: CGW_NET_TIMEOUT=0 leaves a slow-but-working remote alone" {
  # The shim delays ls-remote past the 1s limit, then answers; with the limit off the push proceeds.
  local real_git
  real_git="$(command -v git)"
  cat >"${MOCK_BIN_DIR}/git" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "ls-remote" ]]; then sleep 2; fi
exec "${real_git}" "\$@"
EOF
  chmod +x "${MOCK_BIN_DIR}/git"
  CGW_NET_TIMEOUT=0 run _run_push "--skip-lint --dry-run"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"timed out"* ]]
}

@test "sync_branches: a fetch that hangs fails with the timeout in the log" {
  _hang fetch
  run run_script sync_branches.sh --non-interactive
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Fetch failed"* ]]
  local log
  log="$(cat "${TEST_REPO_DIR}"/logs/*.log 2>/dev/null || true)"
  [[ "${output}${log}" == *"git fetch timed out after 1s"* ]]
}

@test "branch_cleanup --remote --execute: a hung prune shows the timeout, not 'No stale refs'" {
  _hang remote
  run run_script branch_cleanup.sh --execute --remote --non-interactive
  [[ "${output}" == *"git remote prune timed out after 1s"* ]]
  [[ "${output}" != *"No stale remote-tracking refs"* ]]
}
