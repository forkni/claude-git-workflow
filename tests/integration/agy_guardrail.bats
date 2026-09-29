#!/usr/bin/env bats
# tests/integration/agy_guardrail.bats — Tests for agy-block-dangerous-git.sh
# and the configure.sh Antigravity integration.
# Runs: bats tests/integration/agy_guardrail.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'
load '../helpers/mocks'

GUARDRAIL_SCRIPT="${CGW_PROJECT_ROOT}/hooks/agy-block-dangerous-git.sh"

setup() {
  create_test_repo
  setup_mock_bin
  install_mock_lint
}

teardown() {
  cleanup_test_repo
}

# Helper: pipe a command string into the guardrail as an Antigravity toolCall payload
_run_guardrail() {
  local cmd="$1"
  local json
  printf -v json '{"toolCall":{"name":"run_command","args":{"CommandLine":"%s"}}}' "${cmd}"
  bash "${GUARDRAIL_SCRIPT}" <<< "${json}"
}

_run_configure() {
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    export PROJECT_ROOT='${TEST_REPO_DIR}'
    export CGW_NON_INTERACTIVE=1
    bash '${CGW_PROJECT_ROOT}/scripts/git/configure.sh' $*
  "
}

# ── Antigravity guardrail script: blocked commands ────────────────────────────

@test "agy guardrail blocks raw git commit" {
  _require_jq
  run _run_guardrail "git commit -m 'test'"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"deny\" ]]
  [[ "${output}" == *"commit_enhanced.sh"* ]]
}

@test "agy guardrail blocks git commit with no args" {
  _require_jq
  run _run_guardrail "git commit"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"deny\" ]]
}

@test "agy guardrail blocks --no-verify flag" {
  _require_jq
  run _run_guardrail "git push --no-verify origin main"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"deny\" ]]
}

@test "agy guardrail blocks git push --force" {
  _require_jq
  run _run_guardrail "git push --force origin main"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"deny\" ]]
  [[ "${output}" == *"push_validated.sh"* ]]
}

@test "agy guardrail blocks git reset --hard" {
  _require_jq
  run _run_guardrail "git reset --hard HEAD~1"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"deny\" ]]
}

@test "agy guardrail blocks git clean -f" {
  _require_jq
  run _run_guardrail "git clean -fd"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"deny\" ]]
}

@test "agy guardrail blocks git branch -D" {
  _require_jq
  run _run_guardrail "git branch -D old-feature"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"deny\" ]]
}

@test "agy guardrail blocks rm -rf .git" {
  _require_jq
  run _run_guardrail "rm -rf .git"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"deny\" ]]
}

# ── Antigravity guardrail script: allowed commands ────────────────────────────

@test "agy guardrail allows commit_enhanced.sh" {
  _require_jq
  run _run_guardrail "./scripts/git/commit_enhanced.sh 'feat: test'"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"allow\" ]]
}

@test "agy guardrail allows push_validated.sh" {
  _require_jq
  run _run_guardrail "./scripts/git/push_validated.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"allow\" ]]
}

@test "agy guardrail allows git status" {
  _require_jq
  run _run_guardrail "git status"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"allow\" ]]
}

@test "agy guardrail allows git push --force-with-lease" {
  _require_jq
  run _run_guardrail "git push --force-with-lease origin feature"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"allow\" ]]
}

# ── SKIP_CGW_GUARDRAIL env var ────────────────────────────────────────────────

@test "SKIP_CGW_GUARDRAIL=1 bypasses guardrail" {
  _require_jq
  local json
  printf -v json '{"toolCall":{"name":"run_command","args":{"CommandLine":"git commit -m \"raw commit\""}}}'
  run env SKIP_CGW_GUARDRAIL=1 bash "${GUARDRAIL_SCRIPT}" <<< "${json}"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"allow\" ]]
}

# ── configure.sh Antigravity installation ─────────────────────────────────────

@test "configure.sh installs Antigravity skill and hooks.json when .agents exists" {
  _require_jq
  mkdir -p "${TEST_REPO_DIR}/.agents"
  run _run_configure "--non-interactive"
  [ "${status}" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/.agents/skills/auto-git-workflow/SKILL.md" ]
  [ -f "${TEST_REPO_DIR}/.agents/hooks/agy-block-dangerous-git.sh" ]
  [ -f "${TEST_REPO_DIR}/.agents/hooks.json" ]
  grep -q "cgw-git-guardrail" "${TEST_REPO_DIR}/.agents/hooks.json"
}

@test "configure.sh --skip-agy-skill skips Antigravity skill but installs guardrail" {
  _require_jq
  mkdir -p "${TEST_REPO_DIR}/.agents"
  run _run_configure "--non-interactive --skip-agy-skill"
  [ "${status}" -eq 0 ]
  [ ! -f "${TEST_REPO_DIR}/.agents/skills/auto-git-workflow/SKILL.md" ]
  [ -f "${TEST_REPO_DIR}/.agents/hooks.json" ]
}

@test "configure.sh --skip-agy-guardrail skips Antigravity guardrail" {
  _require_jq
  mkdir -p "${TEST_REPO_DIR}/.agents"
  run _run_configure "--non-interactive --skip-agy-guardrail"
  [ "${status}" -eq 0 ]
  [ -f "${TEST_REPO_DIR}/.agents/skills/auto-git-workflow/SKILL.md" ]
  [ ! -f "${TEST_REPO_DIR}/.agents/hooks.json" ]
}

@test "no-jq hooks.json writer emits valid JSON for a command with embedded quotes" {
  _require_jq
  # Regression: the from-scratch printf path interpolated hook_cmd raw, so the
  # local guardrail command (bash -c "if ...") produced malformed JSON that
  # Antigravity could not load, while configure.sh still reported success.
  local hooks_json="${TEST_REPO_DIR}/hooks.json"
  local cmd='bash -c "if [ -f a.sh ]; then exec bash a.sh; else exec bash '"'"'/p/b.sh'"'"'; fi"'
  local cfg="${CGW_PROJECT_ROOT}/scripts/git/configure.sh"
  bash -c "
    $(extract_shell_function "${cfg}" _json_escape_string)
    $(extract_shell_function "${cfg}" _install_agy_guardrail_nojq)
    _install_agy_guardrail_nojq \"\$1\" \"\$2\"
  " _ "${hooks_json}" "${cmd}"
  jq -e . "${hooks_json}" >/dev/null
  local registered
  registered="$(jq -r '."cgw-git-guardrail".PreToolUse[0].hooks[0].command' "${hooks_json}")"
  [ "${registered}" == "${cmd}" ]
}

@test "configure.sh reports failure and leaves a malformed hooks.json untouched" {
  _require_jq
  # Regression: the jq merge result was never checked, so a malformed hooks.json
  # left the guardrail unregistered while configure.sh printed [OK].
  mkdir -p "${TEST_REPO_DIR}/.agents"
  printf '{ not json
' >"${TEST_REPO_DIR}/.agents/hooks.json"
  run _run_configure "--non-interactive"
  [[ "${output}" == *"Guardrail NOT registered"* ]]
  [[ "${output}" != *"Antigravity PreToolUse guardrail registered"* ]]
  [ "$(cat "${TEST_REPO_DIR}/.agents/hooks.json")" == "$(printf '{ not json')" ]
}

@test "configure.sh --skip-antigravity skips both skill and guardrail" {
  _require_jq
  mkdir -p "${TEST_REPO_DIR}/.agents"
  run _run_configure "--non-interactive --skip-antigravity"
  [ "${status}" -eq 0 ]
  [ ! -f "${TEST_REPO_DIR}/.agents/skills/auto-git-workflow/SKILL.md" ]
  [ ! -f "${TEST_REPO_DIR}/.agents/hooks.json" ]
}

@test "configure.sh replaces legacy broken bash -c entry in hooks.json" {
  _require_jq
  mkdir -p "${TEST_REPO_DIR}/.agents"
  cat <<'EOF' >"${TEST_REPO_DIR}/.agents/hooks.json"
{
  "cgw-git-guardrail": {
    "PreToolUse": [
      {
        "matcher": "run_command",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c \"if [ -f .agents/hooks/agy-block-dangerous-git.sh ]; then ...; fi\""
          }
        ]
      }
    ]
  }
}
EOF
  run _run_configure "--non-interactive"
  [ "${status}" -eq 0 ]
  local registered_cmd
  registered_cmd="$(jq -r '."cgw-git-guardrail".PreToolUse[0].hooks[0].command' "${TEST_REPO_DIR}/.agents/hooks.json")"
  [[ "${registered_cmd}" != *"bash -c"* ]]
  [[ "${registered_cmd}" =~ agy-block-dangerous-git ]]
}

@test "registered Antigravity hook command executes without syntax errors via cmd.exe on Windows" {
  _require_jq
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) ;;
    *) skip "Windows cmd.exe test only" ;;
  esac
  mkdir -p "${TEST_REPO_DIR}/.agents"
  run _run_configure "--non-interactive"
  [ "${status}" -eq 0 ]
  local registered_cmd
  registered_cmd="$(jq -r '."cgw-git-guardrail".PreToolUse[0].hooks[0].command' "${TEST_REPO_DIR}/.agents/hooks.json")"
  [ -n "${registered_cmd}" ]
  local payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"git commit -m \"test\""}}}'
  run bash -c "echo '${payload}' | cmd.exe //c \"${registered_cmd}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ \"decision\"[[:space:]]*:[[:space:]]*\"deny\" ]]
  [[ "${output}" != *"syntax error"* ]]
}

