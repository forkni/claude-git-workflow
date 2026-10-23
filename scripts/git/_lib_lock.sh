#!/usr/bin/env bash
# _lib_lock.sh - Index-lock helpers for claude-git-workflow scripts
# Usage: sourced automatically by _common.sh -- do not source directly
#
# Functions:
#   ensure_no_stale_index_lock() - Detect/remove stale .git/index.lock; return 1 if refused/active
#   cgw_run_with_lock_retry()    - Run a mutating command with lock detection and retry
#
# Uses err_tee() and CGW_RC_INDEX_LOCKED from _common.sh, and PROJECT_ROOT, at call time.

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
  # Absolutise if relative (git outputs relative paths when cwd == PROJECT_ROOT,
  # e.g. ".git"; from a linked worktree it's already absolute -- and on
  # Windows/MSYS that means a drive-letter path like "C:/…", which does NOT
  # match a bare "/*" glob, so both forms must be checked or this wrongly
  # re-prefixes an already-absolute Windows path with PROJECT_ROOT).
  [[ "${git_dir}" != /* && "${git_dir}" != [A-Za-z]:/* ]] && git_dir="${PROJECT_ROOT:-.}/${git_dir}"

  local lock_file="${git_dir}/index.lock"
  [[ -f "${lock_file}" ]] || return 0 # fast path: nothing to do

  # Compute lock age in seconds. Clamp negative values (clock skew) to 0.
  local now mtime age
  now="$(date +%s)"
  mtime="$(stat -c %Y "${lock_file}" 2>/dev/null || stat -f %m "${lock_file}" 2>/dev/null)" || {
    err_tee "[cgw-lock] Could not stat ${lock_file}"
    return 1
  }
  age=$((now - mtime))
  ((age < 0)) && age=0

  local max_age="${CGW_INDEX_LOCK_MAX_AGE_SECONDS:-30}"
  local wait_sec="${CGW_INDEX_LOCK_WAIT_SECONDS:-10}"
  local auto_remove="${CGW_AUTO_REMOVE_INDEX_LOCK:-1}"

  if ((age < max_age)); then
    # Lock is fresh — may belong to a concurrent git process. Poll briefly.
    err_tee "[cgw-lock] index.lock is ${age}s old (threshold ${max_age}s); waiting up to ${wait_sec}s..."
    local waited=0
    while ((waited < wait_sec)); do
      sleep 0.5 2>/dev/null || sleep 1 # busybox sleep may not support fractions
      ((waited++))
      [[ ! -f "${lock_file}" ]] && return 0 # lock cleared itself — done
    done
    # Re-compute age after waiting
    now="$(date +%s)"
    mtime="$(stat -c %Y "${lock_file}" 2>/dev/null || stat -f %m "${lock_file}" 2>/dev/null)" || mtime="${now}"
    age=$((now - mtime))
    ((age < 0)) && age=0
    if ((age < max_age)); then
      err_tee "[cgw-lock] Lock still present after ${wait_sec}s wait and age ${age}s < ${max_age}s threshold. Another git process may be active. Stopping."
      return 1
    fi
  fi

  # Refuse to remove the lock while a rebase/merge/cherry-pick/revert/bisect is in
  # progress -- removing it while the operation is paused (e.g. editor open) would corrupt
  # it. Only reached once the lock is stale: a FRESH lock during such an operation is
  # usually a transient IDE/status-bar git process, so it gets the normal wait above
  # (concluding a merge commit, rebase --continue and bisect commits all run in this state).
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

# cgw_run_with_lock_retry - Execute a mutating git command with automatic
# index.lock detection, waiting, and transient retry.
#
# Arguments:
#   $@ - Full git command to execute (e.g. git commit -m "...")
#
# Behavior:
#   1. Runs ensure_no_stale_index_lock before each attempt.
#   2. Executes the command, streaming its stderr live (hook output, editor
#      hints, progress) while also tee-ing a copy to a temporary file.
#   3. If the command succeeds, returns 0.
#   4. If the command fails specifically with an index.lock collision
#      ("index.lock.*File exists" or "Unable to create.*index.lock"),
#      waits with backoff and retries up to CGW_LOCK_RETRY_ATTEMPTS (default: 3).
#   5. If retries are exhausted on an index.lock collision, returns
#      CGW_RC_INDEX_LOCKED; an unrelated error returns the command's own exit
#      code (stderr was already shown as it happened). CGW_LOCK_RETRY_ATTEMPTS
#      below 1 is treated as 1, so the command always runs at least once.
#   6. If the lock check refuses (git never ran), returns CGW_RC_INDEX_LOCKED.
cgw_run_with_lock_retry() {
  local max_attempts="${CGW_LOCK_RETRY_ATTEMPTS:-3}"
  [[ "${max_attempts}" =~ ^[0-9]+$ ]] && ((max_attempts >= 1)) || max_attempts=1
  local retry_delay="${CGW_LOCK_RETRY_DELAY:-1}"
  local attempt=1
  local exit_code=0
  local stderr_file
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/cgw_lock_retry.XXXXXX" 2>/dev/null || echo "${PROJECT_ROOT:-.}/.git/cgw_lock_retry.$$.tmp")"

  local op_name="${1:-command}"
  if [[ "${op_name}" == "git" && -n "${2:-}" ]]; then
    op_name="git ${2}"
  fi

  while ((attempt <= max_attempts)); do
    ensure_no_stale_index_lock || {
      rm -f "${stderr_file}" 2>/dev/null || true
      return "${CGW_RC_INDEX_LOCKED}"
    }

    # stdout goes straight through fd 3; stderr is tee'd so the user sees hook and
    # editor output as it happens while a copy is kept for the collision check.
    # A pipe (not process substitution) keeps this synchronous and bash-3.2 safe.
    : >"${stderr_file}"
    {
      "$@" 2>&1 1>&3 | tee "${stderr_file}" >&2
      exit_code=${PIPESTATUS[0]}
    } 3>&1
    if ((exit_code == 0)); then
      rm -f "${stderr_file}" 2>/dev/null || true
      return 0
    else
      local err_content
      err_content="$(cat "${stderr_file}" 2>/dev/null || true)"

      # Check if error is specifically an index.lock collision
      if [[ "${err_content}" =~ (index\.lock.*(File exists|Permission denied)|Unable to create.*index\.lock) ]]; then
        if ((attempt < max_attempts)); then
          err_tee "[cgw-lock] Index lock collision during '${op_name}' (attempt ${attempt}/${max_attempts}). Retrying in $((attempt * retry_delay))s..."
          sleep $((attempt * retry_delay))
          ((attempt++))
          continue
        fi
        # Retries exhausted: nothing ran, so report a refusal rather than git's raw 128.
        err_tee "[cgw-lock] Index lock still held after ${max_attempts} attempt(s); '${op_name}' did not run."
        exit_code="${CGW_RC_INDEX_LOCKED}"
      fi

      # Unrelated error or retries exhausted (stderr was already streamed above)
      rm -f "${stderr_file}" 2>/dev/null || true
      return "${exit_code}"
    fi
  done

  rm -f "${stderr_file}" 2>/dev/null || true
  return "${exit_code}"
}
