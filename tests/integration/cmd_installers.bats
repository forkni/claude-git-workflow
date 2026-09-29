#!/usr/bin/env bats
# tests/integration/cmd_installers.bats - Regression tests for the Windows
# cmd.exe installers (cgw-install.cmd, cgw-batch-install.cmd).
#
# Bug these tests pin: both installers `pushd` into the target project and
# then invoked bare `bash`. cmd.exe resolves a bare command name against the
# CURRENT DIRECTORY before PATH, and .CMD is in PATHEXT, so a project that
# ships its own `bash.cmd` (Antigravity-enabled projects carry one that
# delegates to a Python shim) shadowed Git's bash.exe. Worse, a batch file
# invoked from a batch file without `call` never returns -- the installer
# chained into the project's bash.cmd and silently terminated right after
# printing "Project: ...": no configure.sh, no staging cleanup, no summary.
#
# Fix: resolve an absolute bash.exe from PATH once (never from cwd) and use
# it for every invocation.
#
# Runs: bats tests/integration/cmd_installers.bats

bats_require_minimum_version 1.5.0
load '../helpers/setup'

_is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

setup() {
  create_temp_dir
}

teardown() {
  cleanup_temp_dir
}

# ── Static guard (runs on every platform) ─────────────────────────────────────

@test "cmd installers never invoke bare 'bash' (cwd-shadowable by a project bash.cmd)" {
  local f
  for f in cgw-install.cmd cgw-batch-install.cmd; do
    run grep -nE '^[[:space:]]*(call[[:space:]]+)?bash([[:space:]]|$)' "${CGW_PROJECT_ROOT}/${f}"
    [ "$status" -ne 0 ] || {
      echo "bare 'bash' invocation in ${f}:"
      echo "$output"
      false
    }
  done
}

@test "cmd installers copy every hooks\\ file they require in the CGW source" {
  # Regression: both installers required hooks\agy-block-dangerous-git.cmd in
  # the source (SOURCE_OK) but never copied it, so configure.sh registered a
  # .agents/hooks/agy-block-dangerous-git.cmd path in hooks.json on Windows
  # that pointed at a file that was never installed.
  local f name required copied missing=""
  for f in cgw-install.cmd cgw-batch-install.cmd; do
    required=$(grep -oE 'if not exist "!CGW_DIR!\\hooks\\[^"]+"' "${CGW_PROJECT_ROOT}/${f}" | sed -E 's/.*\\hooks\\([^"]+)"/\1/' | sort -u)
    copied=$(grep -oE 'copy /y "!CGW_DIR!\\hooks\\[^"]+"' "${CGW_PROJECT_ROOT}/${f}" | sed -E 's/.*\\hooks\\([^"]+)"/\1/' | sort -u)
    [ -n "${required}" ]
    for name in ${required}; do
      grep -qxF "${name}" <<<"${copied}" || missing+="${f}: ${name}"$'\n'
    done
  done
  [ -z "${missing}" ] || {
    printf 'required but never copied:\n%s' "${missing}"
    false
  }
}

# ── Behavioural (Windows only) ────────────────────────────────────────────────

# Builds a CGW-managed git project at $TEST_TMPDIR/proj that also carries a
# top-level bash.cmd (the shadowing shim). Sets PROJ_DIR / BATCH_CONF.
_make_shadowed_project() {
  PROJ_DIR="${TEST_TMPDIR}/proj"
  mkdir -p "${PROJ_DIR}"
  git -C "${PROJ_DIR}" init --quiet
  git -C "${PROJ_DIR}" config user.email "test@example.com"
  git -C "${PROJ_DIR}" config user.name "Test User"
  echo "# proj" > "${PROJ_DIR}/README.md"
  git -C "${PROJ_DIR}" add README.md
  git -C "${PROJ_DIR}" commit --quiet -m "chore: initial commit"

  # Existing .cgw.conf marks it as already CGW-managed (batch updater contract).
  printf 'CGW_LOCAL_FILES=""\nCGW_LINT_CMD=""\nCGW_MARKDOWNLINT_CMD=""\nCGW_TYPECHECK_CMD=""\n' \
    > "${PROJ_DIR}/.cgw.conf"

  # The shadowing shim. If the installer resolves `bash` from cwd it runs
  # this instead of bash.exe -- and never comes back.
  printf '@echo off\r\necho SHADOWED-BASH-CMD\r\n' > "${PROJ_DIR}/bash.cmd"

  BATCH_CONF="${TEST_TMPDIR}/batch.conf"
  printf '%s\r\n' "$(cygpath -w "${PROJ_DIR}")" > "${BATCH_CONF}"
}

@test "cgw-batch-install.cmd completes when the project carries its own bash.cmd" {
  _is_windows || skip "cmd.exe installer test only runs on Windows"
  command -v cmd >/dev/null 2>&1 || skip "cmd.exe not available"

  _make_shadowed_project

  # Claude Code's shell launcher exports NoDefaultCurrentDirectoryInExePath=1,
  # which makes cmd.exe skip the cwd lookup and would mask this bug. A user's
  # normal cmd window does not set it, so clear it to reproduce faithfully.
  run env -u NoDefaultCurrentDirectoryInExePath \
    cmd //c "$(cygpath -w "${CGW_PROJECT_ROOT}/cgw-batch-install.cmd")" \
    "$(cygpath -w "${BATCH_CONF}")" --no-pause

  echo "$output"
  [[ "$output" != *"SHADOWED-BASH-CMD"* ]]
  [[ "$output" == *"[OK] Updated:"* ]]
  [[ "$output" == *"Batch Update Summary"* ]]
  [[ "$output" == *"Updated: 1"* ]]
  [ "$status" -eq 0 ]

  # Staging dirs must have been cleaned up (they were created by this run).
  [ ! -d "${PROJ_DIR}/hooks" ]
  [ ! -d "${PROJ_DIR}/skill" ]
  [ ! -d "${PROJ_DIR}/command" ]
  [ ! -d "${PROJ_DIR}/templates" ]

  # configure.sh actually ran: hooks installed, scripts present.
  [ -f "${PROJ_DIR}/.git/hooks/pre-commit" ]
  [ -f "${PROJ_DIR}/scripts/git/commit_enhanced.sh" ]
}
