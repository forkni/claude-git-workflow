#!/usr/bin/env bash
# _common.sh - Shared utility functions for claude-git-workflow scripts
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
#
# Sourcing this file also sources _config.sh, which:
#   - Auto-detects PROJECT_ROOT (walks up to find .git/)
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
#   ensure_no_stale_index_lock() - Detect/remove stale .git/index.lock; return 1 if refused/active
#   cgw_create_backup_tag() - Create pre-<op>-<ts>-<pid> tag; sets $CGW_BACKUP_TAG
#   cgw_backup_tag_glob()   - Echo glob pattern(s) for backup tag filtering
#   cgw_list_backup_tags()  - Echo existing backup tags; optional op filter
#   cgw_is_local_file()     - Return 0 if path matches any local-only entry (reads CGW_LOCAL_FILES)
#   cgw_filter_local_files() - Filter stdin/args paths; echoes matches; returns 0 if any match
#   cgw_classify_conflicts() - Parse git status into 8 conflict-category arrays; sets CGW_CONFLICT_TOTAL
#   cgw_resolve_safe_conflicts() - Auto-resolve DU/DD, emit halt messages; sets CGW_CONFLICT_STATE
#   cgw_print_conflict_summary() - Print categorised file list from last cgw_classify_conflicts call
#   cgw_confirm()               - Unified confirmation prompt; handles NI mode, literal tokens, defaults

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

  if [[ -d ".venv/Scripts" ]]; then
    # Windows (Git Bash, MSYS)
    # shellcheck disable=SC2034
    PYTHON_BIN=".venv/Scripts"
    # shellcheck disable=SC2034
    PYTHON_EXT=".exe"
  elif [[ -d ".venv/bin" ]]; then
    # Linux, macOS
    # shellcheck disable=SC2034
    PYTHON_BIN=".venv/bin"
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

log_section_start() {
  # Globals: _SECTION_START_TIMES (associative array, keyed by section name)
  # Arguments: section_name, log_path
  local section_name="$1"
  local log_path="$2"
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

log_section_end() {
  # Globals: _SECTION_START_TIMES (associative array, keyed by section name)
  # Arguments: section_name, log_path, exit_code, [error_count]
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
    status="FAILED"
  fi

  echo "[${section_name}] Ended: ${time_str} (${duration}s) - ${status}" | tee -a "${log_path}"
}

run_tool_with_logging() {
  local tool_name="$1"
  local log_path="$2"
  shift 2

  log_section_start "$tool_name" "$log_path"

  TOOL_OUTPUT=$("$@" 2>&1)
  local exit_code=$?

  TOOL_ERROR_COUNT=$(echo "$TOOL_OUTPUT" | grep -cE "^[^:]+:[0-9]+:[0-9]+:" || true)

  if [[ -n "$TOOL_OUTPUT" ]]; then
    echo "$TOOL_OUTPUT" | tee -a "$log_path"
  fi

  log_section_end "$tool_name" "$log_path" "$exit_code" "$TOOL_ERROR_COUNT"

  return $exit_code
}

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

run_git_with_logging() {
  local section_name="$1"
  local log_path="$2"
  shift 2

  log_section_start "$section_name" "$log_path"

  echo "Command: git $*" | tee -a "$log_path"

  GIT_OUTPUT=$(git "$@" 2>&1)
  GIT_EXIT_CODE=$?

  if [[ -n "$GIT_OUTPUT" ]]; then
    echo "$GIT_OUTPUT" | tee -a "$log_path"
  fi

  log_section_end "$section_name" "$log_path" "$GIT_EXIT_CODE"

  return $GIT_EXIT_CODE
}

validate_branch_pair() {
  local src="${1}" tgt="${2}"
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

# ensure_no_stale_index_lock - Detect and auto-remove abandoned .git/index.lock files.
#
# Stale locks (left by crashed/killed git processes) cause:
#   "fatal: Unable to create '.git/index.lock': File exists."
# This helper clears stale locks safely before any git-mutating operation.
#
# Safety: refuses to remove if a rebase/merge/cherry-pick/revert/bisect op is
# in progress (detected via state dirs/sentinel files in the .git dir).
# Handles git worktrees correctly by resolving the real .git dir via git itself.
#
# Honors:
#   CGW_AUTO_REMOVE_INDEX_LOCK   (default 1): 0 = warn-only; 1 = auto-remove stale locks
#   CGW_INDEX_LOCK_MAX_AGE_SECONDS (default 30): locks older than this are stale
#   CGW_INDEX_LOCK_WAIT_SECONDS  (default 10): poll window for fresh locks
#
# Returns:
#   0 - no lock present, OR lock cleared successfully, OR lock cleared during wait
#   1 - refused to remove (op in progress, auto-remove disabled, rm failed, fresh+persistent)
#   2 - environment problem (not a git repo, .git unreadable)
ensure_no_stale_index_lock() {
  # Resolve the real .git dir — handles worktrees where .git is a file, not dir.
  # Use -C PROJECT_ROOT so the result is independent of the caller's cwd.
  local git_dir
  git_dir="$(git -C "${PROJECT_ROOT:-.}" rev-parse --git-dir 2>/dev/null)" || return 2
  # Absolutise if relative (git outputs relative paths when cwd == PROJECT_ROOT).
  [[ "${git_dir}" != /* ]] && git_dir="${PROJECT_ROOT:-.}/${git_dir}"

  local lock_file="${git_dir}/index.lock"
  [[ -f "${lock_file}" ]] || return 0  # fast path: nothing to do

  # Refuse if a git operation is actively in progress — removing the lock
  # while rebase/merge/cherry-pick is paused (e.g. editor open) would corrupt it.
  local -a active_op_sentinels=(
    "${git_dir}/rebase-merge"
    "${git_dir}/rebase-apply"
    "${git_dir}/MERGE_HEAD"
    "${git_dir}/CHERRY_PICK_HEAD"
    "${git_dir}/REVERT_HEAD"
    "${git_dir}/BISECT_LOG"
  )
  local sentinel
  for sentinel in "${active_op_sentinels[@]}"; do
    if [[ -e "${sentinel}" ]]; then
      err_tee "[cgw-lock] REFUSED: git operation in progress (${sentinel##*/}). Resolve or abort it first."
      return 1
    fi
  done

  # Compute lock age in seconds. Clamp negative values (clock skew) to 0.
  local now mtime age
  now="$(date +%s)"
  mtime="$(stat -c %Y "${lock_file}" 2>/dev/null || stat -f %m "${lock_file}" 2>/dev/null)" || {
    err_tee "[cgw-lock] Could not stat ${lock_file}"
    return 1
  }
  age=$(( now - mtime ))
  (( age < 0 )) && age=0

  local max_age="${CGW_INDEX_LOCK_MAX_AGE_SECONDS:-30}"
  local wait_sec="${CGW_INDEX_LOCK_WAIT_SECONDS:-10}"
  local auto_remove="${CGW_AUTO_REMOVE_INDEX_LOCK:-1}"

  if (( age < max_age )); then
    # Lock is fresh — may belong to a concurrent git process. Poll briefly.
    err_tee "[cgw-lock] index.lock is ${age}s old (threshold ${max_age}s); waiting up to ${wait_sec}s..."
    local waited=0
    while (( waited < wait_sec )); do
      sleep 0.5 2>/dev/null || sleep 1  # busybox sleep may not support fractions
      (( waited++ ))
      [[ ! -f "${lock_file}" ]] && return 0  # lock cleared itself — done
    done
    # Re-compute age after waiting
    now="$(date +%s)"
    mtime="$(stat -c %Y "${lock_file}" 2>/dev/null || stat -f %m "${lock_file}" 2>/dev/null)" || mtime="${now}"
    age=$(( now - mtime ))
    (( age < 0 )) && age=0
    if (( age < max_age )); then
      err_tee "[cgw-lock] Lock still present after ${wait_sec}s wait and age ${age}s < ${max_age}s threshold. Another git process may be active. Stopping."
      return 1
    fi
  fi

  # Lock is stale. Remove it (or refuse if auto-remove is disabled).
  if [[ "${auto_remove}" != "1" ]]; then
    err_tee "[cgw-lock] Stale index.lock detected (age ${age}s). CGW_AUTO_REMOVE_INDEX_LOCK=0 — not removing."
    err_tee "[cgw-lock] Run: rm -f \"${lock_file}\""
    return 1
  fi

  err_tee "[cgw-lock] Removing stale index.lock (age ${age}s): ${lock_file}"
  if ! rm -f "${lock_file}"; then
    err_tee "[cgw-lock] Failed to remove ${lock_file} — another process may hold it. Close other git sessions and retry."
    return 1
  fi
  return 0
}

# ── backup-tag module ──────────────────────────────────────────────────────────
# Closed registry of CGW ops that create a backup tag before mutating state.
# To add an op: edit this array AND add a cgw_create_backup_tag call to the script.
declare -gra CGW_BACKUP_OPS=(merge cherry-pick docs-merge bisect rebase undo-commit) 2>/dev/null || true

# Create a lightweight tag pre-<op>-<timestamp>-<pid> at HEAD.
# Sets global CGW_BACKUP_TAG. Warns but always proceeds on git tag failure.
# Returns 1 only if <op> is not in CGW_BACKUP_OPS (programming error in caller).
cgw_create_backup_tag() {
  local op="$1"
  local _found=0 _known
  for _known in "${CGW_BACKUP_OPS[@]}"; do
    [[ "${op}" == "${_known}" ]] && { _found=1; break; }
  done
  if (( _found == 0 )); then
    err "cgw_create_backup_tag: unknown op '${op}' (must be one of: ${CGW_BACKUP_OPS[*]})"
    return 1
  fi
  [[ -z "${timestamp:-}" ]] && get_timestamp
  CGW_BACKUP_TAG="pre-${op}-${timestamp}-$$"
  local _log="${logfile:-/dev/null}"
  if git tag "${CGW_BACKUP_TAG}" >>"${_log}" 2>&1; then
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
  for entry in ${CGW_LOCAL_FILES_EXEMPT:-}; do
    [[ "${path}" == "${entry}" ]] && return 1
  done
  for entry in ${CGW_LOCAL_FILES:-}; do
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
cgw_filter_local_files() {
  local p any=1
  if (( $# > 0 )); then
    for p in "$@"; do
      cgw_is_local_file "${p}" && { echo "${p}"; any=0; }
    done
  else
    while IFS= read -r p; do
      cgw_is_local_file "${p}" && { echo "${p}"; any=0; }
    done
  fi
  return ${any}
}

# ── conflict-policy module ─────────────────────────────────────────────────────
# Single source of truth for git conflict classification and safe auto-resolution.
#
# cgw_classify_conflicts [<porcelain_override>]
#   Parses git status --short (or an optional injected fixture string) into eight
#   category arrays. Returns 0 if any conflicts present, 1 if none.
#
# cgw_resolve_safe_conflicts <op> <original_branch>
#   Owns the policy: auto-resolves DU + DD (propagates failure), re-classifies,
#   emits per-category halt messages with op-specific recovery footer.
#   Sets CGW_CONFLICT_STATE (none|resolved|unresolved). Returns 0 if no manual
#   action needed, 1 if caller should exit 1.

# Conflict-category arrays — reset on every cgw_classify_conflicts call.
declare -g CGW_CONFLICT_DU_FILES=()   # modify/delete   (auto-resolvable: git rm)
declare -g CGW_CONFLICT_DD_FILES=()   # both deleted    (auto-resolvable: git rm)
declare -g CGW_CONFLICT_UU_FILES=()   # both modified   (halt: content conflict)
declare -g CGW_CONFLICT_AU_FILES=()   # add/unmerged    (halt: add-side)
declare -g CGW_CONFLICT_AA_FILES=()   # both added      (halt: add-side)
declare -g CGW_CONFLICT_UD_FILES=()   # deleted by them (halt: accept deletion vs keep ours)
declare -g CGW_CONFLICT_AD_FILES=()   # added by us, deleted by theirs  (halt: keep-ours vs keep-theirs)
declare -g CGW_CONFLICT_DA_FILES=()   # deleted by us, added by theirs  (halt: keep-ours vs keep-theirs)
declare -g CGW_CONFLICT_TOTAL=0
# shellcheck disable=SC2034  # CGW_CONFLICT_STATE is read by callers outside _common.sh
declare -g CGW_CONFLICT_STATE="none"  # none | resolved | unresolved

# shellcheck disable=SC2120  # optional arg used by unit tests; callers inside file omit it
cgw_classify_conflicts() {
  CGW_CONFLICT_DU_FILES=()
  CGW_CONFLICT_DD_FILES=()
  CGW_CONFLICT_UU_FILES=()
  CGW_CONFLICT_AU_FILES=()
  CGW_CONFLICT_AA_FILES=()
  CGW_CONFLICT_UD_FILES=()
  CGW_CONFLICT_AD_FILES=()
  CGW_CONFLICT_DA_FILES=()
  CGW_CONFLICT_TOTAL=0

  local porcelain
  if [[ $# -gt 0 ]]; then
    porcelain="$1"
  else
    porcelain="$(git status --short 2>/dev/null)" || true
  fi

  local line code path
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    code="${line:0:2}"
    path="${line:3}"
    case "${code}" in
      DU) CGW_CONFLICT_DU_FILES+=("${path}"); CGW_CONFLICT_TOTAL=$(( CGW_CONFLICT_TOTAL + 1 )) ;;
      DD) CGW_CONFLICT_DD_FILES+=("${path}"); CGW_CONFLICT_TOTAL=$(( CGW_CONFLICT_TOTAL + 1 )) ;;
      UU) CGW_CONFLICT_UU_FILES+=("${path}"); CGW_CONFLICT_TOTAL=$(( CGW_CONFLICT_TOTAL + 1 )) ;;
      AU) CGW_CONFLICT_AU_FILES+=("${path}"); CGW_CONFLICT_TOTAL=$(( CGW_CONFLICT_TOTAL + 1 )) ;;
      AA) CGW_CONFLICT_AA_FILES+=("${path}"); CGW_CONFLICT_TOTAL=$(( CGW_CONFLICT_TOTAL + 1 )) ;;
      UD) CGW_CONFLICT_UD_FILES+=("${path}"); CGW_CONFLICT_TOTAL=$(( CGW_CONFLICT_TOTAL + 1 )) ;;
      AD) CGW_CONFLICT_AD_FILES+=("${path}"); CGW_CONFLICT_TOTAL=$(( CGW_CONFLICT_TOTAL + 1 )) ;;
      DA) CGW_CONFLICT_DA_FILES+=("${path}"); CGW_CONFLICT_TOTAL=$(( CGW_CONFLICT_TOTAL + 1 )) ;;
    esac
  done <<< "${porcelain}"

  [[ "${CGW_CONFLICT_TOTAL}" -gt 0 ]]
}

# shellcheck disable=SC2034  # CGW_CONFLICT_STATE is read by callers outside _common.sh
cgw_resolve_safe_conflicts() {
  local op="$1" original_branch="$2"
  local _log="${logfile:-/dev/null}"
  CGW_CONFLICT_STATE="none"

  cgw_classify_conflicts
  if [[ "${CGW_CONFLICT_TOTAL}" -eq 0 ]]; then
    return 0
  fi

  # Auto-resolve DU (modify/delete): accept the deletion.
  local f resolution_failed=0
  for f in "${CGW_CONFLICT_DU_FILES[@]}"; do
    echo "  Found modify/delete conflict: ${f}"
    if git rm "${f}" >/dev/null 2>&1; then
      echo "  [OK] Removed: ${f}"
    else
      echo "  [FAIL] Failed to remove ${f}"
      resolution_failed=1
    fi
  done

  # Auto-resolve DD (both deleted): same as DU — propagate failure.
  for f in "${CGW_CONFLICT_DD_FILES[@]}"; do
    echo "  Found both-deleted conflict: ${f}"
    if git rm "${f}" >/dev/null 2>&1; then
      echo "  [OK] Removed (both deleted): ${f}"
    else
      echo "  [FAIL] Failed to remove ${f}"
      resolution_failed=1
    fi
  done

  if [[ "${resolution_failed}" -eq 1 ]]; then
    err_tee "[FAIL] Auto-resolution failed for some files"
    CGW_CONFLICT_STATE="unresolved"
    return 1
  fi

  # Capture auto-resolve count before re-classify resets the arrays.
  local auto_resolved=$(( ${#CGW_CONFLICT_DU_FILES[@]} + ${#CGW_CONFLICT_DD_FILES[@]} ))

  # Re-classify so halt checks see the post-rm state (fixes stale-snapshot bug).
  cgw_classify_conflicts
  if [[ "${CGW_CONFLICT_TOTAL}" -eq 0 ]]; then
    if [[ "${auto_resolved}" -gt 0 ]]; then
      echo "[OK] Auto-resolved modify/delete and both-deleted conflicts" | tee -a "${_log}"
    fi
    CGW_CONFLICT_STATE="resolved"
    return 0
  fi

  if [[ "${auto_resolved}" -gt 0 ]]; then
    echo "[OK] Auto-resolved modify/delete and both-deleted conflicts" | tee -a "${_log}"
  fi

  # Op-specific recovery footer.
  local continue_hint abort_hint
  case "${op}" in
    merge)
      continue_hint="  1. Edit conflicted files
  2. git add <resolved files>
  3. git commit"
      abort_hint="Or abort: git merge --abort && git checkout ${original_branch}" ;;
    cherry-pick)
      continue_hint="  1. Edit conflicted files
  2. git add <resolved files>
  3. git cherry-pick --continue"
      abort_hint="Or abort: git cherry-pick --abort && git checkout ${original_branch}" ;;
    *)
      continue_hint="  1. Edit conflicted files
  2. git add <resolved files>"
      abort_hint="Or restore: git checkout ${original_branch}" ;;
  esac

  local any_halt=0

  # UU — both modified (content conflict)
  if [[ "${#CGW_CONFLICT_UU_FILES[@]}" -gt 0 ]]; then
    echo "" | tee -a "${_log}"
    err_tee "[FAIL] Content conflicts require manual resolution:"
    printf '  %s\n' "${CGW_CONFLICT_UU_FILES[@]}" | tee -a "${_log}"
    echo ""
    echo "Please resolve manually:"
    printf '%s\n' "${continue_hint}"
    echo ""
    printf '%s\n' "${abort_hint}"
    any_halt=1
  fi

  # AU/AA — add-side conflicts
  if [[ $(( ${#CGW_CONFLICT_AU_FILES[@]} + ${#CGW_CONFLICT_AA_FILES[@]} )) -gt 0 ]]; then
    echo "" | tee -a "${_log}"
    err_tee "[FAIL] Add/add or add/unmerged conflicts require manual resolution:"
    [[ "${#CGW_CONFLICT_AU_FILES[@]}" -gt 0 ]] && \
      printf '  %s\n' "${CGW_CONFLICT_AU_FILES[@]}" | tee -a "${_log}"
    [[ "${#CGW_CONFLICT_AA_FILES[@]}" -gt 0 ]] && \
      printf '  %s\n' "${CGW_CONFLICT_AA_FILES[@]}" | tee -a "${_log}"
    echo ""
    echo "Please resolve manually:"
    printf '%s\n' "${continue_hint}"
    echo ""
    printf '%s\n' "${abort_hint}"
    any_halt=1
  fi

  # UD — updated by us, deleted by them
  if [[ "${#CGW_CONFLICT_UD_FILES[@]}" -gt 0 ]]; then
    echo "" | tee -a "${_log}"
    err_tee "[FAIL] Deleted-by-them conflicts require manual resolution:"
    printf '  %s\n' "${CGW_CONFLICT_UD_FILES[@]}" | tee -a "${_log}"
    echo ""
    echo "Please resolve manually (for each file):"
    echo "  Accept deletion: git rm <file>"
    echo "  Keep ours:       git add <file>"
    echo ""
    printf '%s\n' "${abort_hint}"
    any_halt=1
  fi

  # AD/DA — add/delete conflicts
  if [[ $(( ${#CGW_CONFLICT_AD_FILES[@]} + ${#CGW_CONFLICT_DA_FILES[@]} )) -gt 0 ]]; then
    echo "" | tee -a "${_log}"
    err_tee "[FAIL] Add/delete conflicts require manual resolution:"
    [[ "${#CGW_CONFLICT_AD_FILES[@]}" -gt 0 ]] && \
      printf '  %s\n' "${CGW_CONFLICT_AD_FILES[@]}" | tee -a "${_log}"
    [[ "${#CGW_CONFLICT_DA_FILES[@]}" -gt 0 ]] && \
      printf '  %s\n' "${CGW_CONFLICT_DA_FILES[@]}" | tee -a "${_log}"
    echo ""
    echo "Please resolve manually (for each file):"
    echo "  Keep ours:   git checkout --ours <file> && git add <file>"
    echo "  Keep theirs: git checkout --theirs <file> && git add <file>"
    echo ""
    printf '%s\n' "${abort_hint}"
    any_halt=1
  fi

  if [[ "${any_halt}" -eq 1 ]]; then
    CGW_CONFLICT_STATE="unresolved"
    return 1
  fi

  CGW_CONFLICT_STATE="resolved"
  return 0
}

# Print a categorised conflict file list from the most recent cgw_classify_conflicts call.
# Does nothing if CGW_CONFLICT_TOTAL == 0.
cgw_print_conflict_summary() {
  [[ "${CGW_CONFLICT_TOTAL}" -eq 0 ]] && return 0
  local _f
  echo "  Conflicting files:"
  for _f in "${CGW_CONFLICT_UU_FILES[@]}"; do echo "    ${_f} (both modified)"; done
  for _f in "${CGW_CONFLICT_DU_FILES[@]}"; do echo "    ${_f} (modify/delete)"; done
  for _f in "${CGW_CONFLICT_UD_FILES[@]}"; do echo "    ${_f} (deleted by them)"; done
  for _f in "${CGW_CONFLICT_AA_FILES[@]}"; do echo "    ${_f} (both added)"; done
  for _f in "${CGW_CONFLICT_AU_FILES[@]}"; do echo "    ${_f} (add/unmerged)"; done
  for _f in "${CGW_CONFLICT_AD_FILES[@]}"; do echo "    ${_f} (added by us, deleted by theirs)"; done
  for _f in "${CGW_CONFLICT_DA_FILES[@]}"; do echo "    ${_f} (deleted by us, added by theirs)"; done
  for _f in "${CGW_CONFLICT_DD_FILES[@]}"; do echo "    ${_f} (both deleted)"; done
}

# ── lint pipeline module ───────────────────────────────────────────────────────
# Shared helpers for venv-aware binary resolution, file-list selection, lint
# check, format check, lint/format fix, and markdownlint. Callers:
# commit_enhanced.sh, check_lint.sh, fix_lint.sh, .githooks/pre-commit.
#
# cgw_resolve_lint_binary <cmd>
#   Stdout: absolute path to .venv/<cmd>${PYTHON_EXT} when the binary exists in
#   the active venv, else <cmd> verbatim (falls back to system PATH).
#   Reads PYTHON_BIN and PYTHON_EXT — caller must pre-populate via get_python_path.
#   Returns 0 always; pure path resolution, no side effects.

cgw_resolve_lint_binary() {
  local cmd="$1"
  if [[ -n "${PYTHON_BIN:-}" ]] && [[ -f "${PYTHON_BIN}/${cmd}${PYTHON_EXT:-}" ]]; then
    echo "${PYTHON_BIN}/${cmd}${PYTHON_EXT:-}"
  else
    echo "${cmd}"
  fi
}

# cgw_strip_path_arg <args-string>
#   Echo args-string minus its trailing whitespace-delimited token (the path
#   placeholder, typically "."). Used by --modified-only callers to replace the
#   default path with an explicit file list.
cgw_strip_path_arg() {
  echo "${1% *}"
}

# cgw_modified_files_for_lint
#   Stdout: newline-separated list of modified/added files matching
#   CGW_LINT_EXTENSIONS (default: *.py). Outputs nothing when no files match.
#   Caller checks for empty output and decides whether to skip early.
cgw_modified_files_for_lint() {
  local -a lint_exts
  read -r -a lint_exts <<<"${CGW_LINT_EXTENSIONS:-*.py}"
  git diff --name-only --diff-filter=ACMR HEAD -- "${lint_exts[@]}"
}

# cgw_run_lint_check [files...]
#   Runs ${CGW_LINT_CMD} check against the project (no files) or a given file
#   list (strips trailing path token from CGW_LINT_CHECK_ARGS when files given).
#   Honors CGW_SKIP_LINT=1 and empty CGW_LINT_CMD (returns 0, emits skip line).
#   Reads ${logfile} from caller scope. Sets TOOL_ERROR_COUNT via run_tool_with_logging.
#   Returns 0 = clean, 1 = errors found.
cgw_run_lint_check() {
  if [[ "${CGW_SKIP_LINT:-0}" == "1" ]]; then
    echo "  (lint check skipped -- CGW_SKIP_LINT=1)"
    return 0
  fi
  if [[ -z "${CGW_LINT_CMD:-}" ]]; then
    echo "  (lint check skipped -- CGW_LINT_CMD not set)"
    return 0
  fi
  get_python_path 2>/dev/null || true
  local lint_bin
  lint_bin=$(cgw_resolve_lint_binary "${CGW_LINT_CMD}")
  if [[ $# -gt 0 ]]; then
    local stripped_args
    stripped_args=$(cgw_strip_path_arg "${CGW_LINT_CHECK_ARGS:-}")
    # shellcheck disable=SC2086  # Word splitting intentional: stripped_args contains multiple flags
    run_tool_with_logging "LINT CHECK" "${logfile}" "${lint_bin}" ${stripped_args} "$@"
  else
    # shellcheck disable=SC2086  # Word splitting intentional: CGW_LINT_CHECK_ARGS/CGW_LINT_EXCLUDES contain multiple flags
    run_tool_with_logging "LINT CHECK" "${logfile}" "${lint_bin}" ${CGW_LINT_CHECK_ARGS:-} ${CGW_LINT_EXCLUDES:-}
  fi
}

# cgw_run_format_check [files...]
#   Runs ${CGW_FORMAT_CMD} format check. Same file-list and skip conventions as
#   cgw_run_lint_check. Returns 0 silently when CGW_FORMAT_CMD is unset.
cgw_run_format_check() {
  if [[ "${CGW_SKIP_LINT:-0}" == "1" ]]; then
    return 0
  fi
  [[ -z "${CGW_FORMAT_CMD:-}" ]] && return 0
  get_python_path 2>/dev/null || true
  local format_bin
  format_bin=$(cgw_resolve_lint_binary "${CGW_FORMAT_CMD}")
  if [[ $# -gt 0 ]]; then
    local stripped_args
    stripped_args=$(cgw_strip_path_arg "${CGW_FORMAT_CHECK_ARGS:-}")
    # shellcheck disable=SC2086
    run_tool_with_logging "FORMAT CHECK" "${logfile}" "${format_bin}" ${stripped_args} "$@"
  else
    # shellcheck disable=SC2086
    run_tool_with_logging "FORMAT CHECK" "${logfile}" "${format_bin}" ${CGW_FORMAT_CHECK_ARGS:-} ${CGW_FORMAT_EXCLUDES:-}
  fi
}

# cgw_run_lint_fix [files...]
#   Runs lint --fix then format --fix (bundled, since every caller pairs them).
#   Honors CGW_SKIP_LINT=1. Returns 0 if all fixers exited clean; 1 on any error.
#   Returns 0 when neither CGW_LINT_CMD nor CGW_FORMAT_CMD is set.
cgw_run_lint_fix() {
  if [[ "${CGW_SKIP_LINT:-0}" == "1" ]]; then
    echo "  (lint fix skipped -- CGW_SKIP_LINT=1)"
    return 0
  fi
  local fix_failed=0
  if [[ -n "${CGW_LINT_CMD:-}" ]]; then
    get_python_path 2>/dev/null || true
    local lint_bin
    lint_bin=$(cgw_resolve_lint_binary "${CGW_LINT_CMD}")
    if [[ $# -gt 0 ]]; then
      local stripped_args
      stripped_args=$(cgw_strip_path_arg "${CGW_LINT_FIX_ARGS:-}")
      # shellcheck disable=SC2086
      run_tool_with_logging "LINT AUTO-FIX" "${logfile}" "${lint_bin}" ${stripped_args} "$@" || fix_failed=1
    else
      # shellcheck disable=SC2086
      run_tool_with_logging "LINT AUTO-FIX" "${logfile}" "${lint_bin}" ${CGW_LINT_FIX_ARGS:-} ${CGW_LINT_EXCLUDES:-} || fix_failed=1
    fi
  fi
  if [[ -n "${CGW_FORMAT_CMD:-}" ]]; then
    get_python_path 2>/dev/null || true
    local format_bin
    format_bin=$(cgw_resolve_lint_binary "${CGW_FORMAT_CMD}")
    if [[ $# -gt 0 ]]; then
      local stripped_args
      stripped_args=$(cgw_strip_path_arg "${CGW_FORMAT_FIX_ARGS:-}")
      # shellcheck disable=SC2086
      run_tool_with_logging "FORMAT FIX" "${logfile}" "${format_bin}" ${stripped_args} "$@" || fix_failed=1
    else
      # shellcheck disable=SC2086
      run_tool_with_logging "FORMAT FIX" "${logfile}" "${format_bin}" ${CGW_FORMAT_FIX_ARGS:-} ${CGW_FORMAT_EXCLUDES:-} || fix_failed=1
    fi
  fi
  return $fix_failed
}

# cgw_run_markdownlint_check [files...]
#   Runs ${CGW_MARKDOWNLINT_CMD}. Honors CGW_SKIP_MD_LINT=1 and empty
#   CGW_MARKDOWNLINT_CMD (returns 0 silently when unconfigured).
#   Returns 0 = clean (or skipped/unconfigured), 1 = errors found.
cgw_run_markdownlint_check() {
  if [[ "${CGW_SKIP_MD_LINT:-0}" == "1" ]]; then
    echo "  (markdown lint skipped -- CGW_SKIP_MD_LINT=1)"
    return 0
  fi
  [[ -z "${CGW_MARKDOWNLINT_CMD:-}" ]] && return 0
  if [[ $# -gt 0 ]]; then
    # shellcheck disable=SC2086
    run_tool_with_logging "MARKDOWN LINT" "${logfile}" "${CGW_MARKDOWNLINT_CMD}" ${CGW_MARKDOWNLINT_ARGS:-} "$@"
  else
    # shellcheck disable=SC2086
    run_tool_with_logging "MARKDOWN LINT" "${logfile}" "${CGW_MARKDOWNLINT_CMD}" ${CGW_MARKDOWNLINT_ARGS:-}
  fi
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
  echo "${msg}" | grep -qE "^(${CGW_ALL_PREFIXES}):"
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
#   --default yes|no         Empty input maps to yes/no; omit for no default.
#   --literal-token TOKEN    Require exact uppercase token (e.g. FORCE, ROLLBACK).
#   --non-interactive <pol>  Policy when CGW_NON_INTERACTIVE=1 (callers set from --non-interactive flag
#                            or [[ ! -t 0 ]] check):
#                              abort  (default) — exit 1 with error message
#                              accept            — return 0 silently
#                              deny              — return 1 silently

cgw_confirm() {
  local prompt="$1"
  shift
  local default=""
  local literal_token=""
  local ni_policy="abort"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --default)          default="$2";        shift 2 ;;
      --literal-token)    literal_token="$2";  shift 2 ;;
      --non-interactive)  ni_policy="$2";      shift 2 ;;
      *) err "cgw_confirm: unknown option: $1"; return 1 ;;
    esac
  done

  # Non-interactive: env var (set by callers from --non-interactive flag or [[ ! -t 0 ]] check)
  if [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]]; then
    case "${ni_policy}" in
      accept) return 0 ;;
      deny)   return 1 ;;
      abort)
        echo "[!] Non-interactive: '${prompt}' requires confirmation — aborting" >&2
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
      no)  hint=" [no]" ;;
      *)   hint="" ;;
    esac
    read -r -p "${prompt} (yes/no)${hint}: " response
    if [[ -z "${response}" ]]; then
      [[ "${default}" == "yes" ]] && return 0 || return 1
    fi
    [[ "${response}" == "yes" ]] && return 0 || return 1
  fi
}
