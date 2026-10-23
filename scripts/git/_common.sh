#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Alexander Korneev
# SPDX-License-Identifier: MIT
# _common.sh - Shared utility functions for claude-git-workflow scripts
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
#
# Sourcing this file also sources _config.sh, which:
#   - Auto-detects PROJECT_ROOT (git discovery from cwd; SCRIPT_DIR walk fallback)
#   - Loads .cgw.conf if present
#   - Applies CGW_* variable defaults
#
# Available Functions:
#   err()                   - Print error message to STDERR
#   get_timestamp()         - Sets $timestamp variable (yyyyMMdd_HHmmss)
#   init_logging()          - Sets $logfile, $reportfile; creates logs/ dir
#   get_lint_exclusions()   - Sets RUFF_CHECK_EXCLUDE / RUFF_FORMAT_EXCLUDE from CGW config
#   get_python_path()       - Sets PYTHON_BIN and PYTHON_EXT (cross-platform venv detection)
#   log_message()           - Logs message to console and file
#   log_section_start/end() - Section headers with timing (safe for nested calls)
#   run_tool_with_logging() - Run a tool and capture output to log
#   run_git_with_logging()  - Run git command with section logging
#   validate_branch_pair()  - Validate src/tgt branch names and local existence; exit 1 on error
#   cgw_run_pre_op_validation() - Shared pre-op validate_branches.sh re-invoke + log section; returns 1 on failure
#   ensure_no_stale_index_lock() - Detect/remove stale .git/index.lock; return 1 if refused/active [_lib_lock.sh]
#   cgw_create_backup_tag() - Create pre-<op>-<ts>-<pid> tag; sets $CGW_BACKUP_TAG
#   cgw_backup_tag_glob()   - Echo glob pattern(s) for backup tag filtering
#   cgw_list_backup_tags()  - Echo existing backup tags; optional op filter
#   cgw_is_local_file()     - Return 0 if path matches any local-only entry (reads CGW_LOCAL_FILES)
#   cgw_filter_local_files() - Filter stdin/args paths; echoes matches; returns 0 if any match
#   cgw_classify_conflicts() - Parse git status into 8 conflict-category arrays; sets CGW_CONFLICT_TOTAL [_lib_conflict.sh]
#   cgw_resolve_safe_conflicts() - Auto-resolve DU/DD, emit halt messages; sets CGW_CONFLICT_STATE [_lib_conflict.sh]
#   cgw_print_conflict_summary() - Print categorised file list from last cgw_classify_conflicts call [_lib_conflict.sh]
#   cgw_confirm()               - Unified confirmation prompt; handles NI mode, literal tokens, defaults
#   cgw_default_branch()        - Echo the repo's default branch (origin/HEAD, falls back to CGW_TARGET_BRANCH) [_lib_remote.sh]
#   cgw_require_gh()            - Verify gh CLI is installed and authenticated; prints [ERROR] and returns 1 on failure [_lib_remote.sh]
#   cgw_pr_view()               - Echo one field of a PR via gh pr view --jq, CR-stripped [_lib_remote.sh]

# Seam libraries sourced from this file (same directory): _lib_remote.sh, _lib_lock.sh, _lib_conflict.sh,
# _lib_lint.sh.

# SCRIPT_DIR must be set by the caller before sourcing _common.sh:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/_common.sh"
if [[ -z "${SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Source config (sets PROJECT_ROOT + all CGW_* variables)
# shellcheck source=scripts/git/_config.sh
source "${SCRIPT_DIR}/_config.sh"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Error output helper -- always goes to STDERR per style guide
err() {
  echo "[ERROR] $*" >&2
}

# Error helper that also appends to the active logfile (set by init_logging).
# Falls back to stderr-only if logfile is not yet initialised.
err_tee() {
  if [[ -n "${logfile:-}" ]]; then
    echo "$*" | tee -a "${logfile}" >&2
  else
    echo "$*" >&2
  fi
}

# Set GIT_REFLOG_ACTION with the CGW prefix for provenance tracking in git reflogs.
cgw_set_reflog_action() {
  local action="${1:-unknown}"
  local prefix="${CGW_REFLOG_PREFIX:-cgw}"
  export GIT_REFLOG_ACTION="${prefix}: ${action}"
}

# Section timer storage -- associative array avoids global clobbering when
# sections are nested (e.g. run_tool_with_logging called inside another section)
declare -A _SECTION_START_TIMES=() 2>/dev/null || true

get_timestamp() {
  timestamp=$(date +%Y%m%d_%H%M%S)
}

init_logging() {
  local script_name="$1"
  # Use PROJECT_ROOT for an absolute path so logs land in the right place
  # even when the script is invoked from a subdirectory. PROJECT_ROOT is set
  # by _config.sh before any script calls init_logging.
  local log_dir="${PROJECT_ROOT:+${PROJECT_ROOT}/}logs"

  if [[ ! -d "${log_dir}" ]]; then
    mkdir -p "${log_dir}"
  fi

  get_timestamp

  # shellcheck disable=SC2034
  logfile="${log_dir}/${script_name}_${timestamp}.log"
  # shellcheck disable=SC2034
  reportfile="${log_dir}/${script_name}_analysis_${timestamp}.log"
}

get_lint_exclusions() {
  # Build ruff exclusion flags from CGW config variables.
  # Used by check_lint.sh, fix_lint.sh, commit_enhanced.sh.
  # shellcheck disable=SC2034
  RUFF_CHECK_EXCLUDE="${CGW_LINT_EXCLUDES}"
  # shellcheck disable=SC2034
  RUFF_FORMAT_EXCLUDE="${CGW_FORMAT_EXCLUDES}"
}

get_python_path() {
  # CGW_NO_VENV=1 or SKIP_VENV=1: skip venv detection, use system ruff directly
  if [[ "${CGW_NO_VENV:-0}" == "1" ]] || [[ "${SKIP_VENV:-0}" == "1" ]]; then
    # shellcheck disable=SC2034
    PYTHON_BIN=""
    # shellcheck disable=SC2034
    PYTHON_EXT=""
    return 0
  fi

  # CGW_VENV_ROOT (internal; set by check_lint.sh --ref): resolve the venv from
  # that directory instead of the cwd, with an absolute PYTHON_BIN. A snapshot
  # checkout has no .venv of its own (it is untracked), and linking the real
  # one in would risk a recursive delete following the link at cleanup.
  local root="${CGW_VENV_ROOT:+${CGW_VENV_ROOT}/}"

  if [[ -d "${root}.venv/Scripts" ]]; then
    # Windows (Git Bash, MSYS)
    # shellcheck disable=SC2034
    PYTHON_BIN="${root}.venv/Scripts"
    # shellcheck disable=SC2034
    PYTHON_EXT=".exe"
  elif [[ -d "${root}.venv/bin" ]]; then
    # Linux, macOS
    # shellcheck disable=SC2034
    PYTHON_BIN="${root}.venv/bin"
    # shellcheck disable=SC2034
    PYTHON_EXT=""
  else
    # Fallback to system ruff
    if command -v ruff &>/dev/null; then
      # shellcheck disable=SC2034
      PYTHON_BIN=""
      # shellcheck disable=SC2034
      PYTHON_EXT=""
      return 0
    fi
    echo "[ERROR] Virtual environment not found (.venv/Scripts or .venv/bin) and ruff not in PATH" >&2
    return 1
  fi
  return 0
}

log_message() {
  local msg="$1"
  local log_path="$2"

  echo "$msg"
  echo "$msg" >>"$log_path"
}

# log_section_start — print a section header with timestamp and record start time.
# Globals:   _SECTION_START_TIMES (write — records start epoch keyed by section name)
# Arguments: $1 section_name — display label for the section
#            $2 log_path     — file path to append output to
# Returns:   0 always
log_section_start() {
  local section_name="$1"
  local log_path="$2"
  declare -g -A _SECTION_START_TIMES 2>/dev/null || true
  local time_str
  time_str=$(date +%H:%M:%S)
  _SECTION_START_TIMES["${section_name}"]=$(date +%s)

  {
    echo ""
    echo "========================================"
    echo "[${section_name}] Started: ${time_str}"
    echo "========================================"
  } | tee -a "${log_path}"
}

# log_section_end — print a section footer with elapsed time and PASSED/FAILED status.
# Globals:   _SECTION_START_TIMES (read — looks up start epoch by section name)
#            CGW_SECTION_FAIL_LABEL (read, optional — overrides the non-zero
#              status label, e.g. "WARN" for a non-blocking section; defaults
#              to "FAILED" when unset. PASSED is never overridden.)
# Arguments: $1 section_name — must match a prior log_section_start call
#            $2 log_path     — file path to append output to
#            $3 exit_code    — 0 = PASSED, non-zero = FAILED (label may be overridden)
#            $4 error_count  — optional; reserved for future display (default 0)
# Returns:   0 always
log_section_end() {
  local section_name="$1"
  local log_path="$2"
  local exit_code="$3"
  # shellcheck disable=SC2034  # Reserved parameter for future error-count display; not yet used in output
  local error_count="${4:-0}"

  local time_str duration status
  time_str=$(date +%H:%M:%S)
  local end_time start_time
  end_time=$(date +%s)
  start_time="${_SECTION_START_TIMES[${section_name}]:-${end_time}}"
  duration=$((end_time - start_time))

  if [[ ${exit_code} -eq 0 ]]; then
    status="PASSED"
  else
    # Optional caller override (see CGW_SECTION_FAIL_LABEL above), e.g. a
    # non-blocking section prints "WARN" instead of "FAILED".
    status="${CGW_SECTION_FAIL_LABEL:-FAILED}"
  fi

  echo "[${section_name}] Ended: ${time_str} (${duration}s) - ${status}" | tee -a "${log_path}"
}

# Default diagnostic-line pattern, used when CGW_TOOL_ERROR_REGEX is unset. Matches
# both shapes ruff prints: the concise "file:line:col: CODE msg" line, and the
# indented " --> file:line:col" location line of the "full" format (ruff's default
# since 0.5), where the diagnostic line itself carries no location. Each full-format
# diagnostic has exactly one " --> " primary-location line, so it counts once.
# Plain assignment, not readonly: _common.sh has no source guard.
_CGW_DEFAULT_DIAG_REGEX='^[^:]+:[0-9]+:[0-9]+:|^[[:space:]]*--> .+:[0-9]+:[0-9]+'

# run_tool_with_logging — run a command, capture output, log it under a named section.
# Globals:   TOOL_OUTPUT (write — captured stdout+stderr of the command)
#            TOOL_ERROR_COUNT (write — count of lines matching the diagnostic pattern:
#                              file:line:col: or ruff full-format " --> file:line:col")
# Arguments: $1 tool_name — section label shown in log headers
#            $2 log_path  — file path to append output to
#            $@ command   — command and its arguments to execute
# Returns:   exit code of the command
run_tool_with_logging() {
  local tool_name="$1"
  local log_path="$2"
  shift 2

  log_section_start "$tool_name" "$log_path"

  TOOL_OUTPUT=$("$@" 2>&1)
  local exit_code=$?

  # Diagnostic-line pattern: the default matches ruff/flake8-style
  # "file:line:col: ". Tools that emit a different shape (markdownlint-cli2:
  # "file:line[:col] MDxxx/rule ...") never match it, so their real errors
  # counted as 0 while the section still FAILED -- a self-contradicting
  # summary ("Lint FAILED 0 errors ... STATUS: FAILED"). Callers override via
  # a dynamically scoped CGW_TOOL_ERROR_REGEX local (same pattern as
  # CGW_SECTION_FAIL_LABEL).
  TOOL_ERROR_COUNT=$(echo "$TOOL_OUTPUT" | grep -cE "${CGW_TOOL_ERROR_REGEX:-${_CGW_DEFAULT_DIAG_REGEX}}" || true)

  if [[ -n "$TOOL_OUTPUT" ]]; then
    echo "$TOOL_OUTPUT" | tee -a "$log_path"
  fi

  log_section_end "$tool_name" "$log_path" "$exit_code" "$TOOL_ERROR_COUNT"

  return $exit_code
}

# log_summary_table — print a formatted summary table for all lint/format sections.
# Globals:   none
# Arguments: $1 log_path — file path to append output to
#            $@ results  — variadic; each element is "name:status:errors:duration"
# Returns:   0 always
log_summary_table() {
  local log_path="$1"
  shift

  {
    echo ""
    echo "========================================"
    echo "[ERROR SUMMARY]"
    echo "========================================"
    printf "%-14s %-8s %-8s %s\n" "Tool" "Status" "Errors" "Duration"
    printf "%-14s %-8s %-8s %s\n" "----" "------" "------" "--------"

    local total_errors=0
    for result in "$@"; do
      IFS=':' read -r name status errors duration <<<"$result"
      printf "%-14s %-8s %-8s %s\n" "$name" "$status" "$errors" "${duration}s"
      ((total_errors += errors))
    done

    echo ""
    echo "Total: $total_errors errors"
  } | tee -a "$log_path"
}

# CGW_RC_INDEX_LOCKED — exit code run_git_with_logging / cgw_run_with_lock_retry return when
# ensure_no_stale_index_lock refused the lock and git never ran (EX_TEMPFAIL). Callers whose
# failure branch assumes "git ran and hit conflicts" must test for it first.
if [[ -z "${CGW_RC_INDEX_LOCKED:-}" ]]; then
  CGW_RC_INDEX_LOCKED=75
fi

# run_git_with_logging — run a git subcommand, capture output, and log it under a named section.
# Globals:   GIT_OUTPUT (write — captured stdout+stderr of git)
#            GIT_EXIT_CODE (write — exit code of git)
# Arguments: $1 section_name — section label shown in log headers
#            $2 log_path     — file path to append output to
#            $@ git args     — passed directly to git
# Returns:   exit code of git, or CGW_RC_INDEX_LOCKED when the index lock was refused or kept colliding
#            until retries ran out (git did not change anything)
run_git_with_logging() {
  local section_name="$1"
  local log_path="$2"
  shift 2

  # Network subcommands run through cgw_net_git (CGW_NET_TIMEOUT); the rest stay plain git.
  local git_fn=git
  case "${1:-}" in
    push | pull | fetch | clone | ls-remote) git_fn=cgw_net_git ;;
  esac

  log_section_start "$section_name" "$log_path"

  echo "Command: git $*" | tee -a "$log_path"

  local max_attempts="${CGW_LOCK_RETRY_ATTEMPTS:-3}"
  [[ "${max_attempts}" =~ ^[0-9]+$ ]] && ((max_attempts >= 1)) || max_attempts=1
  local retry_delay="${CGW_LOCK_RETRY_DELAY:-1}"
  local attempt=1

  while ((attempt <= max_attempts)); do
    ensure_no_stale_index_lock || {
      GIT_EXIT_CODE="${CGW_RC_INDEX_LOCKED}"
      GIT_OUTPUT="[cgw-lock] Refused due to active operation or stale lock"
      break
    }

    if [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]]; then
      GIT_OUTPUT=$(GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}" GIT_OPTIONAL_LOCKS="${GIT_OPTIONAL_LOCKS:-0}" "${git_fn}" "$@" 2>&1)
    else
      GIT_OUTPUT=$("${git_fn}" "$@" 2>&1)
    fi
    GIT_EXIT_CODE=$?

    if [[ ${GIT_EXIT_CODE} -ne 0 ]] && [[ "${GIT_OUTPUT}" =~ (index\.lock.*(File exists|Permission denied)|Unable to create.*index\.lock) ]]; then
      if ((attempt < max_attempts)); then
        local retry_msg="[cgw-lock] Index lock collision during 'git ${1:-command}' (attempt ${attempt}/${max_attempts}). Retrying in $((attempt * retry_delay))s..."
        err_tee "${retry_msg}"
        echo "${retry_msg}" >>"$log_path"
        sleep $((attempt * retry_delay))
        ((attempt++))
        continue
      fi
      # Retries exhausted: the lock never let git change anything, so report it as a refusal
      # (not git's raw 128, which callers read as "git ran and hit conflicts").
      err_tee "[cgw-lock] Index lock still held after ${max_attempts} attempt(s); 'git ${1:-command}' did not run."
      GIT_EXIT_CODE="${CGW_RC_INDEX_LOCKED}"
    fi
    break
  done

  if [[ -n "$GIT_OUTPUT" ]]; then
    echo "$GIT_OUTPUT" | tee -a "$log_path"
  fi

  log_section_end "$section_name" "$log_path" "$GIT_EXIT_CODE"

  return "${GIT_EXIT_CODE}"
}

validate_branch_pair() {
  local src="${1}" tgt="${2}"
  if [[ -z "${src}" ]]; then
    err "No source branch configured. Pass --source <branch>, or set CGW_SOURCE_BRANCH in .cgw.conf."
    exit 1
  fi
  if ! git check-ref-format --branch "${src}" 2>/dev/null; then
    err "Invalid source branch name: '${src}'"
    exit 1
  fi
  if ! git check-ref-format --branch "${tgt}" 2>/dev/null; then
    err "Invalid target branch name: '${tgt}'"
    exit 1
  fi
  if [[ "${src}" == "${tgt}" ]]; then
    err "Source and target branch are the same: '${src}'"
    exit 1
  fi
  if ! git rev-parse --verify --quiet "refs/heads/${src}" >/dev/null 2>&1; then
    err "Source branch '${src}' does not exist locally"
    exit 1
  fi
  if ! git rev-parse --verify --quiet "refs/heads/${tgt}" >/dev/null 2>&1; then
    err "Target branch '${tgt}' does not exist locally"
    exit 1
  fi
}

# cgw_run_pre_op_validation <op_label> <src> <tgt> <logfile>
# Shared pre-operation validation step used by the merge/cherry-pick/docs-merge family:
# re-invokes validate_branches.sh with the given branch pair via env override (so callers
# don't need to touch CGW_SOURCE_BRANCH/CGW_TARGET_BRANCH globally), wrapped in a named
# log section.
#
# <op_label> drives both the section name ("PRE-<OP_LABEL> VALIDATION") and the noun used
# in pass/fail messages ("aborting <op_label>", "Pre-<op_label> validation passed") --
# e.g. "merge", "cherry-pick", "documentation merge".
#
# Returns 0 on pass, 1 on failure. Does NOT exit -- callers own `|| exit 1`, which keeps
# this testable in isolation (bats can assert the return code without a subshell).
cgw_run_pre_op_validation() {
  local op_label="${1}" src="${2}" tgt="${3}" log_path="${4}"
  local section_name
  section_name="PRE-$(printf '%s' "${op_label}" | tr '[:lower:]' '[:upper:]') VALIDATION"

  log_section_start "${section_name}" "${log_path}"

  if [[ -f "${SCRIPT_DIR}/validate_branches.sh" ]]; then
    if ! CGW_SOURCE_BRANCH="${src}" CGW_TARGET_BRANCH="${tgt}" \
      bash "${SCRIPT_DIR}/validate_branches.sh" >>"${log_path}" 2>&1; then
      err_tee "[FAIL] Validation failed - aborting ${op_label}"
      log_section_end "${section_name}" "${log_path}" "1"
      echo "Please fix validation errors before retrying"
      return 1
    fi
  fi

  echo "[OK] Pre-${op_label} validation passed" | tee -a "${log_path}"
  log_section_end "${section_name}" "${log_path}" "0"
  return 0
}

# Remote/network helpers (cgw_rev_count, cgw_net_git, cgw_remote_*, cgw_default_branch,
# cgw_require_gh, cgw_pr_view) live in _lib_remote.sh. A missing lib returns 1 from this
# file, so the hooks (`source _common.sh || exit 1`) fail closed.
# shellcheck source=scripts/git/_lib_remote.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib_remote.sh" || {
  err "_lib_remote.sh is missing next to _common.sh -- re-run configure.sh or sync_cgw_tooling.sh"
  return 1
}

# Index-lock helpers (ensure_no_stale_index_lock, cgw_run_with_lock_retry) live in _lib_lock.sh.
# A missing lib returns 1 from this file, so the hooks fail closed (see _lib_remote.sh above).
# shellcheck source=scripts/git/_lib_lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib_lock.sh" || {
  err "_lib_lock.sh is missing next to _common.sh -- re-run configure.sh or sync_cgw_tooling.sh"
  return 1
}

# cgw_backup_file <path> — back up <path> without ever clobbering an earlier backup.
#
# The first backup is <path>.bak; if that already exists (e.g. the user's original hook
# saved by an earlier install), the new copy goes to <path>.bak.<YYYYMMDD_HHMMSS> so the
# original survives every later update. Prints the backup path on stdout.
# After a timestamped backup, only the newest CGW_BACKUP_KEEP (3) timestamped backups of <path> are
# kept; the plain <path>.bak -- the user's original -- is never pruned.
# Returns 0 on success, 1 if the copy failed.
CGW_BACKUP_KEEP=3
cgw_backup_file() {
  local src="$1"
  local dest="${src}.bak"
  [[ -e "${dest}" ]] && dest="${src}.bak.$(date +%Y%m%d_%H%M%S)-$$"
  cp "${src}" "${dest}" 2>/dev/null || return 1
  printf '%s\n' "${dest}"
  if [[ "${dest}" != "${src}.bak" ]]; then
    # Timestamps sort lexically, so a reverse sort lists the newest first. Prune failures are
    # cosmetic and never fail the backup.
    local old
    while IFS= read -r old; do
      [[ -n "${old}" ]] && rm -f -- "${old}" 2>/dev/null
    done < <(printf '%s
' "${src}".bak.* | sort -r | tail -n +$((CGW_BACKUP_KEEP + 1)))
  fi
  return 0
}

# cgw_rebase_in_progress — git-dir/worktree-safe rebase-in-progress check.
#
# Uses `git rev-parse --git-path` to resolve the actual state-dir paths,
# so this works with linked worktrees (where .git is a file, not a dir),
# submodules, and relocated GIT_DIR.  Callers must NOT hardcode
# "${PROJECT_ROOT}/.git/rebase-merge" — use this function instead.
#
# Returns 0 if a rebase is in progress, 1 if none.
cgw_rebase_in_progress() {
  local d
  d="$(git rev-parse --git-path rebase-merge 2>/dev/null)" && [[ -d "${d}" ]] && return 0
  d="$(git rev-parse --git-path rebase-apply 2>/dev/null)" && [[ -d "${d}" ]] && return 0
  return 1
}

# cgw_run_local_hook <repo-root> <hook-name> [hook args...] — run the project-local
# .githooks/<hook-name>.local extension, if there is one, and propagate its failure.
#
# .githooks/ is per-clone and git-ignored in some installs, so a linked worktree may have no
# copy: fall back to the main worktree's, as the hooks already do for the CGW tooling. The
# fallback is skipped when the main worktree's path cannot be resolved, so a failed
# `git worktree list` never produces a filesystem-root path like /.githooks/<hook>.local.
# stdin and the hook arguments reach the extension unchanged (pre-push pipes its ref list in).
#
# Returns 0 when there is no extension or it succeeds, 1 when it fails (after printing the
# error banner the hooks used to print themselves).
cgw_run_local_hook() {
  local root="$1" name="$2" hook main_wt
  shift 2
  hook="${root}/.githooks/${name}.local"
  if [[ ! -x "${hook}" ]]; then
    main_wt="$(git worktree list --porcelain 2>/dev/null | head -1)"
    main_wt="${main_wt#worktree }"
    [[ -n "${main_wt}" ]] && hook="${main_wt}/.githooks/${name}.local"
  fi
  [[ -x "${hook}" ]] || return 0
  if ! "${hook}" "$@"; then
    echo "" >&2
    echo "ERROR [${name}]: .githooks/${name}.local failed." >&2
    echo "" >&2
    return 1
  fi
  return 0
}

# ── backup-tag module ──────────────────────────────────────────────────────────
# Closed registry of CGW ops that create a backup tag before mutating state.
# To add an op: edit this array AND add a cgw_create_backup_tag call to the script.
declare -gra CGW_BACKUP_OPS=(merge cherry-pick docs-merge bisect rebase undo-commit recover rollback) 2>/dev/null || true

# Create a lightweight tag pre-<op>-<timestamp>-<pid> at HEAD, or at <ref> when given as $2
# (e.g. a remote tip, for an operation that mutates a branch other than the checked-out one).
# Sets global CGW_BACKUP_TAG. Warns but always proceeds on git tag failure.
# Returns 1 only if <op> is not in CGW_BACKUP_OPS (programming error in caller).
cgw_create_backup_tag() {
  local op="$1"
  local _found=0 _known
  for _known in "${CGW_BACKUP_OPS[@]}"; do
    [[ "${op}" == "${_known}" ]] && {
      _found=1
      break
    }
  done
  if ((_found == 0)); then
    err "cgw_create_backup_tag: unknown op '${op}' (must be one of: ${CGW_BACKUP_OPS[*]})"
    return 1
  fi
  [[ -z "${timestamp:-}" ]] && get_timestamp
  CGW_BACKUP_TAG="pre-${op}-${timestamp}-$$"
  local _log="${logfile:-/dev/null}"
  if git tag "${CGW_BACKUP_TAG}" ${2:+"$2"} >>"${_log}" 2>&1; then
    echo "[OK] Created backup tag: ${CGW_BACKUP_TAG}" | tee -a "${_log}"
  else
    echo "[!] Could not create backup tag: ${CGW_BACKUP_TAG} (continuing)" | tee -a "${_log}"
  fi
  return 0
}

# Echo the glob pattern for the given op, or one pattern per op if no arg.
cgw_backup_tag_glob() {
  local _op="${1:-}"
  if [[ -n "${_op}" ]]; then
    printf 'pre-%s-*\n' "${_op}"
  else
    local _known
    for _known in "${CGW_BACKUP_OPS[@]}"; do
      printf 'pre-%s-*\n' "${_known}"
    done
  fi
}

# Echo existing backup tags (one per line). Pass an op name to filter to one op.
cgw_list_backup_tags() {
  local _op="${1:-}"
  if [[ -n "${_op}" ]]; then
    git tag -l "pre-${_op}-*"
  else
    local _known
    for _known in "${CGW_BACKUP_OPS[@]}"; do
      git tag -l "pre-${_known}-*"
    done
  fi
}

# ── local-only file matcher ────────────────────────────────────────────────────
# Single source of truth for matching paths against CGW_LOCAL_FILES.
# Match contract (no globs):
#   Entry with trailing slash ("dir/") — path matches if path == "dir" OR path == "dir/"*
#   Entry without trailing slash       — exact match (path == entry)
#   CGW_LOCAL_FILES_EXEMPT entries     — exact match suppresses local-file match
# Returns 0 (match) / 1 (no match).
cgw_is_local_file() {
  local path="$1" entry
  local -a _exempt_arr=() _local_arr=()
  read -r -a _exempt_arr <<<"${CGW_LOCAL_FILES_EXEMPT:-}" || true
  read -r -a _local_arr <<<"${CGW_LOCAL_FILES:-}" || true
  for entry in "${_exempt_arr[@]+"${_exempt_arr[@]}"}"; do
    [[ "${path}" == "${entry}" ]] && return 1
  done
  for entry in "${_local_arr[@]+"${_local_arr[@]}"}"; do
    if [[ "${entry}" == */ ]]; then
      local dir="${entry%/}"
      [[ "${path}" == "${dir}" || "${path}" == "${dir}"/* ]] && return 0
    else
      [[ "${path}" == "${entry}" ]] && return 0
    fi
  done
  return 1
}

# Filter paths from stdin (one per line) or positional args.
# Echoes only matching paths to stdout; returns 0 if any matched, 1 if none.
# shellcheck disable=SC2120  # callers pipe paths on stdin; args are optional
cgw_filter_local_files() {
  local p any=1
  if (($# > 0)); then
    for p in "$@"; do
      cgw_is_local_file "${p}" && {
        echo "${p}"
        any=0
      }
    done
  else
    while IFS= read -r p; do
      cgw_is_local_file "${p}" && {
        echo "${p}"
        any=0
      }
    done
  fi
  return ${any}
}

# cgw_guard_incoming_local_files <mode> <ref-or-paths...>
#   Guards commit-producing paths that don't go through commit_enhanced.sh
#   (which already unstages CGW_LOCAL_FILES) against propagating a local-only
#   file into shared history. <mode> selects how the incoming change set is
#   computed; matched paths are reported.
#     merge        — union of files touched by any commit reachable from <ref>
#                    but not HEAD (HEAD..<ref>), so an add-then-delete on the
#                    source branch is still caught even though it nets to no
#                    change in the merge-base..tip tree diff
#     cherry-pick  — files touched by commit <ref>
#     amend        — files in commit <ref> (default HEAD)
#     list         — the paths themselves, passed as args 2..N (e.g. a partial
#                    cherry-pick's selected file subset)
#   Returns 0 = proceed (nothing matched, or override set); 1 = abort.
#   Non-interactive aborts unless CGW_ALLOW_LOCAL_FILES_IN_MERGE=1; interactive
#   prompts (default no). Reuses cgw_filter_local_files / cgw_is_local_file.
cgw_guard_incoming_local_files() {
  local mode="$1" ref="${2:-HEAD}"
  local label="${mode}"
  local -a incoming=() _src_cmd=()
  case "${mode}" in
    merge) _src_cmd=(git log --name-only --pretty=format: "HEAD..${ref}") ;;
    cherry-pick | amend) _src_cmd=(git show --name-only --format= "${ref}") ;;
    list)
      _src_cmd=(printf '%s\n' "${@:2}")
      label="change set"
      ;;
    *)
      err "cgw_guard_incoming_local_files: unknown mode '${mode}'"
      return 2
      ;;
  esac
  local _p
  while IFS= read -r _p; do
    [[ -n "${_p}" ]] && incoming+=("${_p}")
  done < <("${_src_cmd[@]}" 2>/dev/null | cgw_filter_local_files)

  [[ ${#incoming[@]} -eq 0 ]] && return 0

  err_tee "[!] Incoming ${label} carries local-only file(s) that must not enter shared history:"
  local f
  for f in "${incoming[@]}"; do
    err_tee "      ${f}"
  done

  if [[ "${CGW_ALLOW_LOCAL_FILES_IN_MERGE:-0}" == "1" ]]; then
    err_tee "[!] CGW_ALLOW_LOCAL_FILES_IN_MERGE=1 -- proceeding despite local-only files."
    return 0
  fi
  if [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]]; then
    err_tee "[!] Aborting. Remove these files from the incoming change, or set CGW_ALLOW_LOCAL_FILES_IN_MERGE=1 to override."
    return 1
  fi
  cgw_confirm "Proceed and include these local-only file(s)?" --default no
}

# The conflict-policy module (cgw_classify_conflicts, cgw_resolve_safe_conflicts, ...) lives in
# _lib_conflict.sh. A missing lib returns 1 from this file, so the hooks fail closed.
# shellcheck source=scripts/git/_lib_conflict.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib_conflict.sh" || {
  err "_lib_conflict.sh is missing next to _common.sh -- re-run configure.sh or sync_cgw_tooling.sh"
  return 1
}

# The lint pipeline module (cgw_lint_plan, cgw_run_lint_check, cgw_run_typecheck, cgw_validated_path_set, ...)
# lives in _lib_lint.sh. A missing lib returns 1 from this file, so the hooks fail closed.
# shellcheck source=scripts/git/_lib_lint.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib_lint.sh" || {
  err "_lib_lint.sh is missing next to _common.sh -- re-run configure.sh or sync_cgw_tooling.sh"
  return 1
}

# ── commit-message format module ───────────────────────────────────────────────
# Validates commit messages against the conventional-commit prefix grammar.
#
# cgw_validate_commit_message <msg>
#   Returns 0 if msg matches ^(<CGW_ALL_PREFIXES>): grammar, 1 otherwise.
#   Pure predicate — no stdout/stderr output. Caller owns all user-facing
#   messages and merge-commit skipping (parent-count check).

cgw_validate_commit_message() {
  local msg="$1"
  # Conventional-commits prefix with an optional scope and optional breaking-
  # change marker: "type:", "type(scope):", "type!:", "type(scope)!:". The
  # bare "type:"-only pattern rejected valid scoped prefixes (fix(pyccsl):)
  # with a generic warning, sending agents into the wrapper source to find
  # this regex and then stripping the scope to get through.
  echo "${msg}" | grep -qE "^(${CGW_ALL_PREFIXES})(\([A-Za-z0-9._/-]+\))?!?:"
}

# cgw_branch_matches_freeform_glob <branch>
#   Returns 0 if <branch> matches any glob in CGW_FREEFORM_MESSAGE_BRANCHES.
#   Pure predicate, no output. Empty branch or empty setting: always 1 -- an
#   empty branch (e.g. a non-refs/heads/* push target) must never match a
#   bare "*" glob.
cgw_branch_matches_freeform_glob() {
  local branch="$1" pat
  [[ -z "${branch}" ]] && return 1
  local -a _pats=()
  read -r -a _pats <<<"${CGW_FREEFORM_MESSAGE_BRANCHES:-}" || true
  for pat in "${_pats[@]+"${_pats[@]}"}"; do
    # shellcheck disable=SC2053  # unquoted RHS is the point: glob match
    [[ "${branch}" == ${pat} ]] && return 0
  done
  return 1
}

# cgw_branch_is_freeform <branch>
#   Returns 0 if <branch> matches CGW_FREEFORM_MESSAGE_BRANCHES AND is not a
#   guarded branch (CGW_SOURCE_BRANCH, CGW_TARGET_BRANCH, or any entry of
#   CGW_PROTECTED_BRANCHES). Guarded branches are exempt-proof by design: an
#   overbroad glob (e.g. "*") must never silently turn off conventional-
#   format enforcement on the branches CGW's own policy protects. Pure
#   predicate, no output -- callers print their own "pattern ignored" notice
#   once they know which case applies.
cgw_branch_is_freeform() {
  local branch="$1"
  cgw_branch_matches_freeform_glob "${branch}" || return 1
  cgw_branch_is_protected "${branch}" --policy guarded && return 1
  return 0
}

# cgw_branch_is_guarded <branch>
#   Returns 0 if <branch> exactly matches CGW_SOURCE_BRANCH, CGW_TARGET_BRANCH,
#   or any entry of CGW_PROTECTED_BRANCHES -- i.e. the branch a freeform glob
#   is not allowed to exempt. Pure predicate, no output. Used by callers to
#   decide whether to print the "pattern ignored" notice.
cgw_branch_is_guarded() {
  cgw_branch_is_protected "$1" --policy guarded
}

# cgw_freeform_message_check <msg>
#   Delegated gate for a freeform branch's commit message, e.g. the target
#   project's own commit-msg hook. Returns 0 (nothing to enforce) when
#   CGW_FREEFORM_MESSAGE_CHECK is unset. Otherwise writes <msg> to a temp
#   file and runs CGW_FREEFORM_MESSAGE_CHECK with that file as $1; returns
#   the command's exit status. A relative command resolves against
#   PROJECT_ROOT. Fails closed (returns 1) if the command cannot be found or
#   is not executable -- a silently-skipped delegated gate is worse than a
#   blocked commit. The command's own stdout/stderr passes through; this
#   function prints nothing itself.
cgw_freeform_message_check() {
  local msg="$1"
  [[ -z "${CGW_FREEFORM_MESSAGE_CHECK:-}" ]] && return 0

  local cmd="${CGW_FREEFORM_MESSAGE_CHECK}"
  if [[ "${cmd}" != /* ]]; then
    cmd="${PROJECT_ROOT}/${cmd}"
  fi
  if [[ ! -x "${cmd}" ]]; then
    err "CGW_FREEFORM_MESSAGE_CHECK is set to '${CGW_FREEFORM_MESSAGE_CHECK}' but '${cmd}' is not an executable file"
    return 1
  fi

  local msgfile
  msgfile="$(mktemp)" || return 1
  printf '%s\n' "${msg}" >"${msgfile}"
  "${cmd}" "${msgfile}"
  local status=$?
  rm -f "${msgfile}"
  return ${status}
}

# cgw_run_staged_checks
#   Project-specific commit gates scoped by path. CGW_STAGED_CHECKS holds one
#   entry per line: `<glob> [<glob>...] :: <command>`. An entry runs when any
#   staged path (added, copied, modified, renamed) matches one of its bash
#   globs (`*` crosses `/`, so `dev/tests/*` covers the whole subtree). The
#   command runs through `bash -c` from PROJECT_ROOT, with the matching paths
#   newline-separated in CGW_CHECK_FILES; nothing is appended to its argv, so
#   a whole-tree check (a test file, a baseline scan) runs as written. Like
#   the lint step it reads the working tree. Every matching entry runs, and
#   the first failure does not stop the rest, so one commit attempt reports
#   every broken gate. Blank lines and lines starting with `#` are skipped; a
#   line without ` :: ` is reported and counts as a failure (fail closed: a
#   typo must not silently drop a gate). Returns 0 when nothing is configured,
#   nothing matched, or every matching check passed; 1 otherwise.
cgw_run_staged_checks() {
  [[ -z "${CGW_STAGED_CHECKS:-}" ]] && return 0

  local -a staged=()
  local f
  while IFS= read -r f; do
    [[ -n "${f}" ]] && staged+=("${f}")
  done < <(git diff --cached --name-only --diff-filter=ACMR)
  [[ ${#staged[@]} -eq 0 ]] && return 0

  local failed=0 line globs cmd g matched
  local -a glob_list=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    if [[ "${line}" != *" :: "* ]]; then
      err "CGW_STAGED_CHECKS entry has no ' :: ' separator: ${line}"
      failed=1
      continue
    fi
    globs="${line%% :: *}"
    cmd="${line#* :: }"
    read -r -a glob_list <<<"${globs}"
    matched=""
    for f in "${staged[@]}"; do
      for g in "${glob_list[@]}"; do
        # shellcheck disable=SC2053 # ${g} is a glob on purpose
        if [[ "${f}" == ${g} ]]; then
          matched+="${f}"$'\n'
          break
        fi
      done
    done
    [[ -z "${matched}" ]] && continue
    echo "  Staged check (${globs}): ${cmd}"
    if (cd "${PROJECT_ROOT}" && CGW_CHECK_FILES="${matched%$'\n'}" bash -c "${cmd}"); then
      echo "[OK] Staged check passed: ${cmd}"
    else
      err "Staged check failed: ${cmd}"
      failed=1
    fi
  done <<<"${CGW_STAGED_CHECKS}"
  return ${failed}
}

# ── interactive prompts module ─────────────────────────────────────────────────
# Unified confirmation prompt. Centralises all yes/no and literal-token
# prompts so non-interactive policy, grammar, and default-value handling
# are consistent across every script.
#
# cgw_confirm <prompt> [--default yes|no] [--literal-token TOKEN] [--non-interactive abort|accept|deny]
#   Returns 0 = confirmed (proceed), 1 = denied (skip).
#   Exits 1  = non-interactive + abort policy (fatal — terminates the script).
#
#   --default yes|no         Empty or unrecognized input maps to yes/no; omit for no default.
#   --literal-token TOKEN    Require exact uppercase token (e.g. FORCE, ROLLBACK). Case-sensitive.
#   --non-interactive <pol>  Policy when CGW_NON_INTERACTIVE=1 (callers set from --non-interactive flag
#                            or [[ ! -t 0 ]] check):
#                              abort  (default) — exit 1 with error message
#                              accept            — return 0 silently
#                              deny              — return 1 silently
#
#   Standard mode accepts case-insensitive y/yes (→ 0) and n/no (→ 1).
#   Unrecognized input falls back to --default (deny if no default set).

cgw_confirm() {
  local prompt="$1"
  shift
  local default=""
  local literal_token=""
  local ni_policy="abort"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --default)
        default="$2"
        shift 2
        ;;
      --literal-token)
        literal_token="$2"
        shift 2
        ;;
      --non-interactive)
        ni_policy="$2"
        shift 2
        ;;
      *)
        err "cgw_confirm: unknown option: $1"
        return 1
        ;;
    esac
  done

  # Non-interactive: env var (set by callers from --non-interactive flag or [[ ! -t 0 ]] check)
  if [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]]; then
    case "${ni_policy}" in
      accept) return 0 ;;
      deny) return 1 ;;
      abort)
        echo "[!] non-interactive: '${prompt}' requires confirmation — aborting (no --yes exists for this prompt by design; run the command in your own terminal)" >&2
        exit 1
        ;;
    esac
  fi

  # Interactive prompt
  if [[ -n "${literal_token}" ]]; then
    read -r -p "${prompt} " response
    [[ "${response}" == "${literal_token}" ]] && return 0 || return 1
  else
    local hint
    case "${default}" in
      yes) hint=" [yes]" ;;
      no) hint=" [no]" ;;
      *) hint="" ;;
    esac
    read -r -p "${prompt} (yes/no)${hint}: " response
    if [[ -z "${response}" ]]; then
      [[ "${default}" == "yes" ]] && return 0 || return 1
    fi
    case "${response}" in
      [Yy] | [Yy][Ee][Ss]) return 0 ;;
      [Nn] | [Nn][Oo]) return 1 ;;
      # Unrecognized input falls back to default (deny if no default set).
      *) [[ "${default}" == "yes" ]] && return 0 || return 1 ;;
    esac
  fi
}

# ── operation preconditions module ──────────────────────────────────────────
# Centralises repository invariant checks: branch protection policies and
# working-tree cleanliness verification before mutating operations.

# cgw_branch_is_protected <branch> [--policy <guarded|cleanup|push>]
#   Pure predicate. Returns 0 if <branch> is protected under the named policy.
#   Returns 1 if not protected or <branch> is empty.
#
# Policies:
#   guarded (default):
#     CGW_SOURCE_BRANCH, CGW_TARGET_BRANCH, and any entry of CGW_PROTECTED_BRANCHES.
#     Used by freeform branch checks so globs never exempt policy branches.
#   cleanup:
#     CGW_SOURCE_BRANCH, CGW_TARGET_BRANCH, main, master, $(cgw_default_branch),
#     and any entry of CGW_PROTECTED_BRANCHES.
#     Used by branch_cleanup.sh to prevent deleting active or stable branches.
#   push:
#     Any entry of CGW_PROTECTED_BRANCHES.
#     Used by push_validated.sh to require FORCE confirmation tokens.
cgw_branch_is_protected() {
  local branch="${1:-}"
  shift || return 1
  [[ -z "${branch}" ]] && return 1
  branch="${branch#refs/heads/}"

  local policy="guarded"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --policy)
        policy="${2:-guarded}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  local -a _protected_set=()
  local -a _pb_arr=()
  read -r -a _pb_arr <<<"${CGW_PROTECTED_BRANCHES:-}" || true

  case "${policy}" in
    push)
      _protected_set=("${_pb_arr[@]+"${_pb_arr[@]}"}")
      ;;
    cleanup)
      _protected_set=("${CGW_TARGET_BRANCH:-}" "${CGW_SOURCE_BRANCH:-}" main master)
      local def_branch
      def_branch=$(cgw_default_branch 2>/dev/null || echo "")
      [[ -n "${def_branch}" ]] && _protected_set+=("${def_branch}")
      _protected_set+=("${_pb_arr[@]+"${_pb_arr[@]}"}")
      ;;
    guarded | *)
      _protected_set=("${CGW_SOURCE_BRANCH:-}" "${CGW_TARGET_BRANCH:-}" "${_pb_arr[@]+"${_pb_arr[@]}"}")
      ;;
  esac

  [[ ${#_protected_set[@]} -eq 0 ]] && return 1
  local pb
  for pb in "${_protected_set[@]+"${_protected_set[@]}"}"; do
    [[ -n "${pb}" && "${branch}" == "${pb}" ]] && return 0
  done
  return 1
}

# cgw_tree_dirty_paths
#   Emits the paths of uncommitted tracked changes and any skip-worktree /
#   assume-unchanged files whose disk content diverged from HEAD (including
#   files deleted on disk). Untracked files are excluded. Pure scanner, no side effects.
cgw_tree_dirty_paths() {
  # 1. Uncommitted tracked changes (both staged and unstaged)
  git status --porcelain --untracked-files=no 2>/dev/null | sed -e 's/^...//'

  # 2. Skip-worktree or assume-unchanged paths that diverged from HEAD
  local sw_files f
  sw_files=$(git ls-files -v 2>/dev/null | grep '^[a-zS]' | cut -c3-)
  if [[ -n "${sw_files}" ]]; then
    while IFS= read -r f; do
      [[ -z "${f}" ]] && continue
      local disk_hash index_hash
      index_hash=$(git rev-parse ":${f}" 2>/dev/null || true)
      [[ -z "${index_hash}" ]] && continue
      if [[ ! -e "${f}" ]]; then
        echo "${f}"
        continue
      fi
      disk_hash=$(git hash-object --path="${f}" "${f}" 2>/dev/null || true)
      if [[ -z "${disk_hash}" || "${disk_hash}" != "${index_hash}" ]]; then
        echo "${f}"
      fi
    done <<<"${sw_files}"
  fi
}

# cgw_is_tree_clean
#   Pure predicate. Returns 0 if working tree has no uncommitted tracked changes
#   and no diverged skip-worktree paths; returns 1 if dirty.
cgw_is_tree_clean() {
  local dirty
  dirty=$(cgw_tree_dirty_paths | head -n 1)
  [[ -z "${dirty}" ]]
}

# cgw_require_clean_tree [--on-dirty <fail|stash|confirm-abort|confirm-stash>]
#                        [--reason <text>] [--stash-msg <text>]
#   Asserts that the working tree is clean. On dirty state, executes the named
#   policy:
#     fail (default):
#       Prints explanatory error and recovery steps to stderr/log, returns 1.
#     stash:
#       Auto-stashes changes via `git stash push`, sets _CGW_TREE_WAS_STASHED=1,
#       returns 0 on success, 1 on stash failure.
#     confirm-abort:
#       Warns changes will be lost, prompts user to continue; aborts (returns 1)
#       if rejected or in non-interactive mode.
#     confirm-stash:
#       Prompts user to auto-stash; stashes and sets _CGW_TREE_WAS_STASHED=1
#       on accept, or aborts (returns 1) if declined.
cgw_require_clean_tree() {
  local on_dirty="fail"
  local reason="operation needs a clean tree"
  local stash_msg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --on-dirty)
        on_dirty="${2:-fail}"
        shift 2
        ;;
      --reason)
        reason="${2:-operation needs a clean tree}"
        shift 2
        ;;
      --stash-msg)
        stash_msg="${2:-}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  _CGW_TREE_WAS_STASHED=0

  cgw_is_tree_clean && return 0

  case "${on_dirty}" in
    fail)
      local msg="[FAIL] Working tree has uncommitted changes -- ${reason}"
      if [[ -n "${logfile:-}" && -f "${logfile}" ]]; then
        echo "${msg}" | tee -a "$logfile" >&2
        {
          echo "  Recovery:"
          echo "    1. ./scripts/git/stash_work.sh push   # set aside local changes"
          echo "    2. re-run this operation"
          echo "    3. ./scripts/git/stash_work.sh pop    # restore your changes"
          echo "  Or commit them first: ./scripts/git/commit_enhanced.sh \"<type>: <msg>\""
        } | tee -a "$logfile" >&2
      else
        echo "${msg}" >&2
        echo "  Recovery:" >&2
        echo "    1. ./scripts/git/stash_work.sh push   # set aside local changes" >&2
        echo "    2. re-run this operation" >&2
        echo "    3. ./scripts/git/stash_work.sh pop    # restore your changes" >&2
        echo "  Or commit them first: ./scripts/git/commit_enhanced.sh \"<type>: <msg>\"" >&2
      fi
      return 1
      ;;
    stash)
      local s_msg="${stash_msg:-cgw auto-stash $(date +%Y%m%d_%H%M%S)}"
      if [[ -n "${logfile:-}" && -f "${logfile}" ]]; then
        echo "  Stashing uncommitted changes..." | tee -a "$logfile"
        if git stash push -m "${s_msg}" 2>&1 | tee -a "$logfile"; then
          _CGW_TREE_WAS_STASHED=1
          echo "  [OK] Changes stashed" | tee -a "$logfile"
          return 0
        else
          echo "[ERROR] Failed to stash changes -- resolve conflicts first" | tee -a "$logfile" >&2
          return 1
        fi
      else
        echo "  Stashing uncommitted changes..."
        if git stash push -m "${s_msg}" 2>&1; then
          _CGW_TREE_WAS_STASHED=1
          echo "  [OK] Changes stashed"
          return 0
        else
          echo "[ERROR] Failed to stash changes -- resolve conflicts first" >&2
          return 1
        fi
      fi
      ;;
    confirm-abort)
      if [[ -n "${logfile:-}" && -f "${logfile}" ]]; then
        echo "[!] WARNING: Uncommitted changes detected" | tee -a "$logfile"
        echo "" | tee -a "$logfile"
        git status --short | tee -a "$logfile"
        echo "" | tee -a "$logfile"
        echo "These changes will be LOST during ${reason}!" | tee -a "$logfile"
        echo "" | tee -a "$logfile"
      else
        echo "[!] WARNING: Uncommitted changes detected"
        echo ""
        git status --short
        echo ""
        echo "These changes will be LOST during ${reason}!"
        echo ""
      fi
      if ! cgw_confirm "Continue anyway?" --non-interactive abort; then
        if [[ -n "${logfile:-}" && -f "${logfile}" ]]; then
          echo "" | tee -a "$logfile"
          echo "Operation cancelled" | tee -a "$logfile"
          echo "Please commit or stash changes first" | tee -a "$logfile"
        else
          echo ""
          echo "Operation cancelled"
          echo "Please commit or stash changes first"
        fi
        return 1
      fi
      return 0
      ;;
    confirm-stash)
      if [[ -n "${logfile:-}" && -f "${logfile}" ]]; then
        echo "[!] Uncommitted changes detected -- will auto-stash during ${reason}" | tee -a "$logfile"
        git status --short | tee -a "$logfile"
        echo "" | tee -a "$logfile"
      else
        echo "[!] Uncommitted changes detected -- will auto-stash during ${reason}"
        git status --short
        echo ""
      fi
      if ! cgw_confirm "Auto-stash changes and proceed?" --non-interactive accept; then
        if [[ -n "${logfile:-}" && -f "${logfile}" ]]; then
          echo "Aborted -- commit or stash manually before ${reason}" | tee -a "$logfile"
        else
          echo "Aborted -- commit or stash manually before ${reason}"
        fi
        return 1
      fi
      local s_msg="${stash_msg:-cgw auto-stash $(date +%Y%m%d_%H%M%S)}"
      if [[ -n "${logfile:-}" && -f "${logfile}" ]]; then
        echo "  Stashing uncommitted changes..." | tee -a "$logfile"
        if git stash push -m "${s_msg}" >>"$logfile" 2>&1; then
          _CGW_TREE_WAS_STASHED=1
          echo "  [OK] Changes stashed" | tee -a "$logfile"
          return 0
        else
          echo "[ERROR] Failed to stash changes" | tee -a "$logfile" >&2
          return 1
        fi
      else
        echo "  Stashing uncommitted changes..."
        if git stash push -m "${s_msg}" >/dev/null 2>&1; then
          _CGW_TREE_WAS_STASHED=1
          echo "  [OK] Changes stashed"
          return 0
        else
          echo "[ERROR] Failed to stash changes" >&2
          return 1
        fi
      fi
      ;;
  esac
  return 0
}
