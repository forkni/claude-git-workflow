#!/usr/bin/env bats
# tests/unit/config.bats - Unit tests for _config.sh defaults and variable handling
# Runs: bats tests/unit/config.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

FIXTURES_DIR="${BATS_TEST_DIRNAME}/../fixtures"

# Helper: source _config.sh in a subshell within a real git repo
# Usage: source_config [var=val ...]
# Returns: stdout is "key=value" pairs for the variables we want to inspect
_source_config() {
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${CGW_PROJECT_ROOT}/scripts/git'
    $*
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"CGW_SOURCE_BRANCH=\${CGW_SOURCE_BRANCH}\"
    echo \"CGW_TARGET_BRANCH=\${CGW_TARGET_BRANCH}\"
    echo \"CGW_LINT_CMD=\${CGW_LINT_CMD}\"
    echo \"CGW_MERGE_MODE=\${CGW_MERGE_MODE}\"
    echo \"CGW_ALL_PREFIXES=\${CGW_ALL_PREFIXES}\"
    echo \"CGW_NON_INTERACTIVE=\${CGW_NON_INTERACTIVE}\"
    echo \"CGW_NO_VENV=\${CGW_NO_VENV}\"
    echo \"CGW_STAGED_ONLY=\${CGW_STAGED_ONLY}\"
    echo \"PROJECT_ROOT=\${PROJECT_ROOT}\"
  "
}

setup() {
  create_test_repo
}

teardown() {
  cleanup_test_repo
}

# ── Default values ─────────────────────────────────────────────────────────────

@test "CGW_SOURCE_BRANCH defaults to 'development'" {
  result=$(_source_config)
  [[ "${result}" == *"CGW_SOURCE_BRANCH=development"* ]]
}

@test "CGW_TARGET_BRANCH defaults to 'main'" {
  result=$(_source_config)
  [[ "${result}" == *"CGW_TARGET_BRANCH=main"* ]]
}

@test "CGW_LINT_CMD defaults to 'ruff'" {
  result=$(_source_config)
  [[ "${result}" == *"CGW_LINT_CMD=ruff"* ]]
}

@test "CGW_MERGE_MODE defaults to 'direct'" {
  result=$(_source_config)
  [[ "${result}" == *"CGW_MERGE_MODE=direct"* ]]
}

@test "CGW_NON_INTERACTIVE defaults to '0'" {
  result=$(_source_config)
  [[ "${result}" == *"CGW_NON_INTERACTIVE=0"* ]]
}

# ── CGW_ALL_PREFIXES construction ──────────────────────────────────────────────

@test "CGW_ALL_PREFIXES without extras contains base prefixes" {
  result=$(_source_config)
  prefix_line=$(echo "${result}" | grep "^CGW_ALL_PREFIXES=")
  [[ "${prefix_line}" == *"feat"* ]]
  [[ "${prefix_line}" == *"fix"* ]]
  [[ "${prefix_line}" == *"docs"* ]]
  [[ "${prefix_line}" == *"chore"* ]]
}

@test "CGW_ALL_PREFIXES without extras does not include extra separator" {
  result=$(_source_config)
  prefix_line=$(echo "${result}" | grep "^CGW_ALL_PREFIXES=")
  # Should be exactly the base prefixes string
  [[ "${prefix_line}" == "CGW_ALL_PREFIXES=feat|fix|docs|chore|test|refactor|style|perf" ]]
}

@test "CGW_ALL_PREFIXES with CGW_EXTRA_PREFIXES appends extras" {
  result=$(_source_config "export CGW_EXTRA_PREFIXES=cuda|tensorrt")
  prefix_line=$(echo "${result}" | grep "^CGW_ALL_PREFIXES=")
  [[ "${prefix_line}" == *"cuda"* ]]
  [[ "${prefix_line}" == *"tensorrt"* ]]
  [[ "${prefix_line}" == *"feat"* ]]
}

@test "CGW_ALL_PREFIXES with extras uses pipe separator" {
  result=$(_source_config "export CGW_EXTRA_PREFIXES=myprefix")
  prefix_line=$(echo "${result}" | grep "^CGW_ALL_PREFIXES=")
  [[ "${prefix_line}" == *"|myprefix"* ]]
}

# ── Environment variable override ─────────────────────────────────────────────

@test "CGW_LINT_CMD env var overrides default" {
  result=$(_source_config "export CGW_LINT_CMD=eslint")
  [[ "${result}" == *"CGW_LINT_CMD=eslint"* ]]
}

@test "CGW_SOURCE_BRANCH env var overrides default" {
  result=$(_source_config "export CGW_SOURCE_BRANCH=dev")
  [[ "${result}" == *"CGW_SOURCE_BRANCH=dev"* ]]
}

@test "CGW_MERGE_MODE env var 'pr' is respected" {
  result=$(_source_config "export CGW_MERGE_MODE=pr")
  [[ "${result}" == *"CGW_MERGE_MODE=pr"* ]]
}

# ── .cgw.conf loading ─────────────────────────────────────────────────────────

@test ".cgw.conf values override built-in defaults" {
  cp "${FIXTURES_DIR}/sample.cgw.conf" "${TEST_REPO_DIR}/.cgw.conf"
  result=$(_source_config)
  [[ "${result}" == *"CGW_SOURCE_BRANCH=feature"* ]]
  [[ "${result}" == *"CGW_TARGET_BRANCH=stable"* ]]
  [[ "${result}" == *"CGW_LINT_CMD=eslint"* ]]
}

@test ".cgw.conf CGW_EXTRA_PREFIXES is included in ALL_PREFIXES" {
  cp "${FIXTURES_DIR}/sample.cgw.conf" "${TEST_REPO_DIR}/.cgw.conf"
  result=$(_source_config)
  prefix_line=$(echo "${result}" | grep "^CGW_ALL_PREFIXES=")
  [[ "${prefix_line}" == *"cuda"* ]]
  [[ "${prefix_line}" == *"tensorrt"* ]]
}

@test "env var takes priority over .cgw.conf" {
  cp "${FIXTURES_DIR}/sample.cgw.conf" "${TEST_REPO_DIR}/.cgw.conf"
  # .cgw.conf sets CGW_LINT_CMD=eslint; env should win
  result=$(_source_config "export CGW_LINT_CMD=golangci-lint")
  [[ "${result}" == *"CGW_LINT_CMD=golangci-lint"* ]]
}

# ── Backward compatibility mappings ───────────────────────────────────────────

@test "CLAUDE_GIT_NON_INTERACTIVE=1 sets CGW_NON_INTERACTIVE=1" {
  result=$(_source_config "export CLAUDE_GIT_NON_INTERACTIVE=1")
  [[ "${result}" == *"CGW_NON_INTERACTIVE=1"* ]]
}

@test "CLAUDE_GIT_NO_VENV=1 sets CGW_NO_VENV=1" {
  result=$(_source_config "export CLAUDE_GIT_NO_VENV=1")
  [[ "${result}" == *"CGW_NO_VENV=1"* ]]
}

@test "CLAUDE_GIT_STAGED_ONLY=1 sets CGW_STAGED_ONLY=1" {
  result=$(_source_config "export CLAUDE_GIT_STAGED_ONLY=1")
  [[ "${result}" == *"CGW_STAGED_ONLY=1"* ]]
}

# ── PROJECT_ROOT detection ────────────────────────────────────────────────────

@test "PROJECT_ROOT is set to a non-empty value" {
  result=$(_source_config)
  project_root=$(echo "${result}" | grep "^PROJECT_ROOT=" | cut -d= -f2-)
  [ -n "${project_root}" ]
}

@test "PROJECT_ROOT points to a directory containing .git" {
  result=$(_source_config)
  project_root=$(echo "${result}" | grep "^PROJECT_ROOT=" | cut -d= -f2-)
  [ -d "${project_root}/.git" ]
}
