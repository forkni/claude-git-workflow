#!/usr/bin/env bats
# tests/unit/config.bats - Unit tests for _config.sh defaults and variable handling
# Runs: bats tests/unit/config.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

FIXTURES_DIR="${BATS_TEST_DIRNAME}/../fixtures"

# Helper: source _config.sh in a subshell within a real git repo
# Usage: _source_config [shell_statement ...]
# Returns: stdout is "key=value" pairs for the variables we want to inspect
# Note: SCRIPT_DIR is set inside the test repo so _detect_project_root() finds
# the test repo's .git/ (not the real project root) when loading .cgw.conf.
_source_config() {
  mkdir -p "${TEST_REPO_DIR}/scripts/git"
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
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

@test "CGW_SOURCE_BRANCH has no default (empty when unconfigured)" {
  # SOURCE is an inherently per-operation choice ("what am I merging"), not a repo-wide
  # fact -- it must never be silently guessed. Empty is the correct "unconfigured" state;
  # validate_branch_pair (_common.sh) surfaces a clear error for scripts that need one.
  result=$(_source_config)
  source_line=$(echo "${result}" | grep "^CGW_SOURCE_BRANCH=")
  [[ "${source_line}" == "CGW_SOURCE_BRANCH=" ]]
}

@test "CGW_TARGET_BRANCH auto-detects local 'main' when no origin/HEAD is set" {
  # create_test_repo has a local 'main' branch and no remote -- target is a repo-wide
  # fact, so it's auto-detected at source time even with no .cgw.conf.
  result=$(_source_config)
  [[ "${result}" == *"CGW_TARGET_BRANCH=main"* ]]
}

@test "_config.sh sourced directly survives a repo with no origin remote (regression)" {
  # Regression for a bug where "_cgw_detected_target=\"\$(git symbolic-ref ...)\"" let
  # `git symbolic-ref`'s non-zero exit (no origin/HEAD ref) propagate as the assignment's
  # own exit status. The test above ("auto-detects local 'main'...") exercises the same
  # repo shape but goes through _source_config's `bash -c` subshell, which does NOT run
  # under bats' errexit trap and so never caught this. This test sources _config.sh
  # directly in the test body -- exactly how _common.sh's callers (e.g. common.bats'
  # setup()) do it -- so it runs under bats' `set -e` and reproduces the real crash:
  # sourcing aborted entirely wherever origin/HEAD is unset, which is always true right
  # after actions/checkout on CI (no local main/master fallback ever ran).
  cd "${TEST_REPO_DIR}"
  export SCRIPT_DIR="${TEST_REPO_DIR}/scripts/git"
  # shellcheck source=scripts/git/_config.sh
  source "${CGW_PROJECT_ROOT}/scripts/git/_config.sh"
  [[ "${CGW_TARGET_BRANCH}" == "main" ]]
}

@test "CGW_TARGET_BRANCH falls back to 'master' when no 'main' branch exists" {
  # Independent minimal repo (not create_test_repo, which always creates 'main').
  local repo="${TEST_TMPDIR}/master-repo"
  mkdir -p "${repo}/scripts/git"
  git -C "${repo}" init --quiet --initial-branch=master
  git -C "${repo}" config user.email "test@example.com"
  git -C "${repo}" config user.name "Test User"
  git -C "${repo}" commit --quiet --allow-empty -m "chore: initial commit"

  result=$(bash -c "
    cd '${repo}'
    export SCRIPT_DIR='${repo}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"CGW_TARGET_BRANCH=\${CGW_TARGET_BRANCH}\"
  ")
  [[ "${result}" == *"CGW_TARGET_BRANCH=master"* ]]
}

@test "CGW_TARGET_BRANCH prefers origin/HEAD over local branch names" {
  local repo="${TEST_TMPDIR}/head-repo"
  local remote="${TEST_TMPDIR}/head-remote.git"
  mkdir -p "${repo}/scripts/git"
  git init --bare --quiet "${remote}"
  git -C "${repo}" init --quiet
  git -C "${repo}" config user.email "test@example.com"
  git -C "${repo}" config user.name "Test User"
  # Default branch name here is irrelevant -- origin/HEAD should win regardless.
  git -C "${repo}" checkout --quiet -b release
  git -C "${repo}" commit --quiet --allow-empty -m "chore: initial commit"
  git -C "${repo}" remote add origin "${remote}"
  git -C "${repo}" push --quiet origin release
  git -C "${repo}" remote set-head origin release

  result=$(bash -c "
    cd '${repo}'
    export SCRIPT_DIR='${repo}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"CGW_TARGET_BRANCH=\${CGW_TARGET_BRANCH}\"
  ")
  [[ "${result}" == *"CGW_TARGET_BRANCH=release"* ]]
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

@test "CGW_LOCAL_FILES_EXEMPT defaults to empty" {
  # The matcher uses CGW_LOCAL_FILES_EXEMPT to suppress matches; default must be empty
  # so an unconfigured project doesn't accidentally exempt files.
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    [[ -z \"\${CGW_LOCAL_FILES_EXEMPT}\" ]]
  "
}

# ── Centralized runtime-gate defaults (F2) ─────────────────────────────────────

@test "F2: runtime-gate defaults are defined in _config.sh when unset" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    unset CGW_SKIP_LINT CGW_SKIP_MD_LINT CGW_SKIP_TYPECHECK CGW_ALL \
          CGW_TYPECHECK_CMD CGW_TYPECHECK_CHECK_ARGS CGW_TYPECHECK_EXCLUDES
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"SKIP_LINT=\${CGW_SKIP_LINT}\"
    echo \"SKIP_MD_LINT=\${CGW_SKIP_MD_LINT}\"
    echo \"SKIP_TYPECHECK=\${CGW_SKIP_TYPECHECK}\"
    echo \"ALL=\${CGW_ALL}\"
    echo \"TC_CMD=[\${CGW_TYPECHECK_CMD}]\"
    echo \"TC_ARGS=\${CGW_TYPECHECK_CHECK_ARGS}\"
    echo \"TC_EX=[\${CGW_TYPECHECK_EXCLUDES}]\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SKIP_LINT=0"* ]]
  [[ "${output}" == *"SKIP_MD_LINT=0"* ]]
  [[ "${output}" == *"SKIP_TYPECHECK=0"* ]]
  [[ "${output}" == *"ALL=0"* ]]
  [[ "${output}" == *"TC_CMD=[]"* ]]
  [[ "${output}" == *"TC_ARGS=check"* ]]
  [[ "${output}" == *"TC_EX=[]"* ]]
}

@test "F2: an explicitly-set gate value is preserved (+x semantics, not overridden)" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    export CGW_SKIP_LINT=1
    export CGW_TYPECHECK_CMD=pyrefly
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"SKIP_LINT=\${CGW_SKIP_LINT}\"
    echo \"TC_CMD=\${CGW_TYPECHECK_CMD}\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SKIP_LINT=1"* ]]
  [[ "${output}" == *"TC_CMD=pyrefly"* ]]
}

# ── Markdown-lint config split (A1) ────────────────────────────────────────────

@test "A1: CGW_MARKDOWNLINT_ARGS defaults to exclusions only; PATHS holds the glob" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    unset CGW_MARKDOWNLINT_ARGS CGW_MARKDOWNLINT_PATHS
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"ARGS=[\${CGW_MARKDOWNLINT_ARGS}]\"
    echo \"PATHS=[\${CGW_MARKDOWNLINT_PATHS}]\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ARGS=[!CLAUDE.md !MEMORY.md]"* ]]
  [[ "${output}" == *"PATHS=[**/*.md]"* ]]
  # ARGS must not carry a scan glob.
  [[ "${output}" != *"ARGS=[**"* ]]
}

@test "A1: legacy conflated CGW_MARKDOWNLINT_ARGS (with glob) warns" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    export CGW_MARKDOWNLINT_ARGS='**/*.md !CLAUDE.md !MEMORY.md'
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
  " 2>&1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"WARNING"* ]]
  [[ "${output}" == *"CGW_MARKDOWNLINT_PATHS"* ]]
}

@test "G5: exclusion-only ARGS with glob chars ('!*.tmp') does NOT warn" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    export CGW_MARKDOWNLINT_ARGS='!*.tmp !CLAUDE.md --config .mdlintrc'
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
  " 2>&1
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"WARNING: CGW_MARKDOWNLINT_ARGS"* ]]
}

# ── Markdown-lint runtime auto-detection (A) ────────────────────────────────────
# _cgw_detect_markdownlint() (_config.sh) shells out to `command -v` for
# markdownlint-cli2/markdownlint/npx. The real dev machine (and possibly CI) may
# have real markdownlint tooling on PATH, so these tests override the `command`
# builtin with a same-named shell function that fakes only those three lookups
# and delegates everything else to `builtin command "$@"` -- deterministic
# regardless of what is actually installed.

@test "A: no markdownlint tooling on PATH -> CGW_MARKDOWNLINT_CMD resolves empty" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    command() {
      case \"\$2\" in
        markdownlint-cli2|markdownlint|npx) return 1 ;;
        *) builtin command \"\$@\" ;;
      esac
    }
    unset CGW_MARKDOWNLINT_CMD
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"CMD=[\${CGW_MARKDOWNLINT_CMD}]\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CMD=[]"* ]]
}

@test "A: no binary but npx present + fallback enabled (default) -> npx --yes markdownlint-cli2" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    command() {
      case \"\$2\" in
        markdownlint-cli2|markdownlint) return 1 ;;
        npx) return 0 ;;
        *) builtin command \"\$@\" ;;
      esac
    }
    unset CGW_MARKDOWNLINT_CMD CGW_MARKDOWNLINT_NPX_FALLBACK
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"CMD=[\${CGW_MARKDOWNLINT_CMD}]\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CMD=[npx --yes markdownlint-cli2]"* ]]
}

@test "A: no binary, npx present, CGW_MARKDOWNLINT_NPX_FALLBACK=0 -> resolves empty" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    command() {
      case \"\$2\" in
        markdownlint-cli2|markdownlint) return 1 ;;
        npx) return 0 ;;
        *) builtin command \"\$@\" ;;
      esac
    }
    unset CGW_MARKDOWNLINT_CMD
    export CGW_MARKDOWNLINT_NPX_FALLBACK=0
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"CMD=[\${CGW_MARKDOWNLINT_CMD}]\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CMD=[]"* ]]
}

@test "A: markdownlint-cli2 present -> takes priority over markdownlint and npx" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    command() {
      case \"\$2\" in
        markdownlint-cli2|markdownlint|npx) return 0 ;;
        *) builtin command \"\$@\" ;;
      esac
    }
    unset CGW_MARKDOWNLINT_CMD
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"CMD=[\${CGW_MARKDOWNLINT_CMD}]\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CMD=[markdownlint-cli2]"* ]]
}

@test "A: explicit CGW_MARKDOWNLINT_CMD=\"\" opts out regardless of detectable tooling" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    command() {
      case \"\$2\" in
        markdownlint-cli2|markdownlint|npx) return 0 ;;
        *) builtin command \"\$@\" ;;
      esac
    }
    export CGW_MARKDOWNLINT_CMD=''
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"CMD=[\${CGW_MARKDOWNLINT_CMD}]\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CMD=[]"* ]]
}

@test "A: explicit CGW_MARKDOWNLINT_CMD env var wins over auto-detection" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    command() {
      case \"\$2\" in
        markdownlint-cli2|markdownlint|npx) return 1 ;;
        *) builtin command \"\$@\" ;;
      esac
    }
    export CGW_MARKDOWNLINT_CMD='custom-tool'
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"CMD=[\${CGW_MARKDOWNLINT_CMD}]\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"CMD=[custom-tool]"* ]]
}

# ── {files} placeholder defaults (A2+A3) ───────────────────────────────────────

@test "A3: lint/format arg defaults use the {files} placeholder" {
  run bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    unset CGW_LINT_CHECK_ARGS CGW_LINT_FIX_ARGS CGW_FORMAT_CHECK_ARGS CGW_FORMAT_FIX_ARGS
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    echo \"LC=\${CGW_LINT_CHECK_ARGS}\"
    echo \"LF=\${CGW_LINT_FIX_ARGS}\"
    echo \"FC=\${CGW_FORMAT_CHECK_ARGS}\"
    echo \"FF=\${CGW_FORMAT_FIX_ARGS}\"
  "
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"LC=check {files}"* ]]
  [[ "${output}" == *"LF=check --fix {files}"* ]]
  [[ "${output}" == *"FC=format --check {files}"* ]]
  [[ "${output}" == *"FF=format {files}"* ]]
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
  result=$(_source_config "export CGW_EXTRA_PREFIXES='cuda|tensorrt'")
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

@test ".cgw.conf with CRLF line endings is read correctly" {
  # Regression: when a Windows editor saves .cgw.conf with CRLF, the trailing
  # \r leaked into variable values and broke quote-stripping (e.g.
  # CGW_LINT_CMD became literal '"ruff"\r', causing 'command not found').
  sed 's/$/\r/' "${FIXTURES_DIR}/sample.cgw.conf" > "${TEST_REPO_DIR}/.cgw.conf"
  result=$(_source_config)
  [[ "${result}" == *"CGW_SOURCE_BRANCH=feature"* ]]
  [[ "${result}" == *"CGW_TARGET_BRANCH=stable"* ]]
  [[ "${result}" == *"CGW_LINT_CMD=eslint"* ]]
}

@test ".cgw.conf inline comment after value is stripped" {
  # Regression: configure.sh emits lines like
  #   CGW_LINT_CMD=""  # no lint tool detected; set to enable
  # The comment leaked into the value, making CGW_LINT_CMD literal '""  # ...',
  # which then failed as 'command not found'.
  cat >"${TEST_REPO_DIR}/.cgw.conf" <<'EOF'
CGW_SOURCE_BRANCH="feature"  # source branch
CGW_TARGET_BRANCH="stable"   # target branch
CGW_LINT_CMD=""              # no lint tool detected; set to enable
EOF
  result=$(_source_config)
  [[ "${result}" == *"CGW_SOURCE_BRANCH=feature"* ]]
  [[ "${result}" == *"CGW_TARGET_BRANCH=stable"* ]]
  [[ "${result}" == *"CGW_LINT_CMD="* ]]
  # CGW_LINT_CMD must be EMPTY, not '""  # no lint tool detected...'
  lint_line=$(echo "${result}" | grep "^CGW_LINT_CMD=")
  [[ "${lint_line}" == "CGW_LINT_CMD=" ]]
}

@test ".cgw.conf hash inside quoted value is preserved" {
  # The inline-comment stripper must NOT touch # characters inside a quoted value.
  cat >"${TEST_REPO_DIR}/.cgw.conf" <<'EOF'
CGW_LOCAL_FILES="foo #notacomment bar"
EOF
  result=$(_source_config)
  # Confirm the # was kept inside the value (we don't echo CGW_LOCAL_FILES from
  # the helper, so source again here and inspect directly).
  bash -c "
    cd '${TEST_REPO_DIR}'
    export SCRIPT_DIR='${TEST_REPO_DIR}/scripts/git'
    source '${CGW_PROJECT_ROOT}/scripts/git/_config.sh'
    [[ \"\${CGW_LOCAL_FILES}\" == 'foo #notacomment bar' ]]
  "
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
