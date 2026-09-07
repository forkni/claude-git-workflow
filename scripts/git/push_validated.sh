#!/usr/bin/env bash
# push_validated.sh - Validated git push with safety checks
# Purpose: Push with remote reachability check, behind-remote warning, and force-push protection
# Usage: ./scripts/git/push_validated.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR              - Directory containing this script
#   PROJECT_ROOT            - Auto-detected git repo root (set by _config.sh)
#   logfile                 - Set by init_logging
#   CGW_PROTECTED_BRANCHES  - Branches requiring --force confirmation (default: target branch)
# Arguments:
#   --non-interactive   Skip prompts
#   --dry-run           Show what would be pushed without pushing
#   --skip-lint         Skip pre-push lint check
#   --skip-md-lint      Skip markdown lint only in pre-push check
#   --no-venv           Forward to check_lint.sh: use system lint tool (no .venv)
#   --force             Allow force-push (uses an explicit --force-with-lease=<ref>:<sha>)
#   --branch <name>     Override push target branch (default: current branch)
#   -h, --help          Show help
# Returns:
#   0 on successful push, 1 on failure or safety abort

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

init_logging "push_validated"
ensure_no_stale_index_lock || exit 1

main() {
  local dry_run=0
  local skip_lint=0
  local skip_md_lint=0
  local no_venv=0
  local force_push=0
  local target_branch=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --help | -h)
        echo "Usage: ./scripts/git/push_validated.sh [OPTIONS]"
        echo ""
        echo "Push the current branch to origin with safety checks."
        echo ""
        echo "Options:"
        echo "  --non-interactive   Skip all prompts"
        echo "  --dry-run           Show what would be pushed without pushing"
        echo "  --skip-lint         Skip pre-push lint check (all lint)"
        echo "  --skip-md-lint      Skip markdown lint only in pre-push check"
        echo "  --no-venv           Forward to check_lint.sh: use system lint tool (no .venv)"
        echo "  --force             Allow force-push (uses an explicit --force-with-lease=<ref>:<sha>)"
        echo "  --branch <name>     Override push target branch (default: current branch)"
        echo "  -h, --help          Show this help"
        echo ""
        echo "Safety checks performed:"
        echo "  - Verifies the configured remote (CGW_REMOTE) is reachable"
        echo "  - Blocks force-push to protected branches without explicit --force"
        echo "  - Warns if local branch is behind remote (may overwrite remote work)"
        echo "  - Optional pre-push lint check"
        echo ""
        echo "Environment:"
        echo "  CGW_NON_INTERACTIVE=1         Same as --non-interactive"
        echo "  CGW_REMOTE                    Remote name (default: origin)"
        echo "  CGW_PROTECTED_BRANCHES=<list> Space-separated protected branch names"
        echo "  (Also: CLAUDE_GIT_NON_INTERACTIVE, CLAUDE_GIT_NO_VENV)"
        exit 0
        ;;
      --non-interactive)
        CGW_NON_INTERACTIVE=1
        ;;
      --dry-run) dry_run=1 ;;
      --skip-lint) skip_lint=1 ;;
      --skip-md-lint) skip_md_lint=1 ;;
      --no-venv) no_venv=1 ;;
      --force) force_push=1 ;;
      --branch)
        target_branch="${2:-}"
        shift
        ;;
      *)
        echo "[ERROR] Unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  [[ "${CGW_SKIP_LINT:-0}" == "1" ]] && skip_lint=1
  [[ "${CGW_SKIP_MD_LINT:-0}" == "1" ]] && skip_md_lint=1
  [[ "${CGW_NO_VENV:-0}" == "1" ]] && no_venv=1

  {
    echo "========================================="
    echo "Push Validated Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Working Directory: ${PROJECT_ROOT}"
  } >"$logfile"

  echo "=== Validated Push ===" | tee -a "$logfile"
  echo "" | tee -a "$logfile"
  echo "Workflow Log: ${logfile}" | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  # [1/5] Determine push branch
  log_section_start "BRANCH CHECK" "$logfile"

  local current_branch
  current_branch=$(git branch --show-current)

  if [[ -z "${target_branch}" ]]; then
    target_branch="${current_branch}"
  fi

  if [[ -z "${target_branch}" ]]; then
    err "Cannot determine current branch (detached HEAD?)"
    log_section_end "BRANCH CHECK" "$logfile" "1"
    exit 1
  fi

  echo "Branch to push: ${target_branch}" | tee -a "$logfile"
  echo "Remote: ${CGW_REMOTE}" | tee -a "$logfile"

  # Check force-push protection against configured protected branches
  local is_protected=0
  local -a _pb_arr=()
  read -r -a _pb_arr <<<"${CGW_PROTECTED_BRANCHES:-}" || true
  for protected in "${_pb_arr[@]+"${_pb_arr[@]}"}"; do
    if [[ "${target_branch}" == "${protected}" ]]; then
      is_protected=1
      break
    fi
  done

  if [[ ${is_protected} -eq 1 ]] && [[ ${force_push} -eq 1 ]]; then
    echo "[!] WARNING: Force-push to protected branch '${target_branch}' requested!" | tee -a "$logfile"
    echo "  This rewrites remote history and affects all collaborators." | tee -a "$logfile"
    if ! cgw_confirm "Type 'FORCE' to confirm force-push to ${target_branch}" --literal-token FORCE --non-interactive abort; then
      echo "  Aborted" | tee -a "$logfile"
      log_section_end "BRANCH CHECK" "$logfile" "1"
      exit 1
    fi
  elif [[ ${is_protected} -eq 1 ]] && [[ ${force_push} -eq 0 ]]; then
    echo "[OK] Pushing to ${target_branch} (normal push)" | tee -a "$logfile"
  fi

  log_section_end "BRANCH CHECK" "$logfile" "0"
  echo "" | tee -a "$logfile"

  # [2/5] Check remote reachability
  log_section_start "REMOTE CHECK" "$logfile"

  echo "Checking remote ${CGW_REMOTE}..." | tee -a "$logfile"
  if ! cgw_remote_reachable "${CGW_REMOTE}"; then
    err "Remote '${CGW_REMOTE}' is not reachable. Check network/auth."
    log_section_end "REMOTE CHECK" "$logfile" "1"
    exit 1
  fi
  echo "[OK] Remote '${CGW_REMOTE}' is reachable" | tee -a "$logfile"

  # Does the branch already exist on the remote? A brand-new branch has no
  # remote tip to compare against and needs no force-with-lease guard in [5/5].
  # ls-remote queries the remote directly -- unlike the fetch below, it does
  # not depend on the remote's configured fetch refspec covering this branch.
  local remote_branch_exists=0
  if cgw_remote_branch_exists "${CGW_REMOTE}" "${target_branch}"; then
    remote_branch_exists=1
  fi

  # Check if local is behind remote. Fetch with an explicit refspec (not just
  # `git fetch <remote> <branch>`, which only guarantees FETCH_HEAD) so
  # refs/remotes/<remote>/<branch> is always written, even when the remote's
  # configured fetch refspec doesn't cover this branch (single-branch clones,
  # narrowed remote.*.fetch -- common in fork/CI setups). The same tracking
  # ref is what the force-push lease in [5/5] is built from.
  local state_known=1
  if [[ ${remote_branch_exists} -eq 1 ]]; then
    if ! git fetch "${CGW_REMOTE}" \
      "+refs/heads/${target_branch}:refs/remotes/${CGW_REMOTE}/${target_branch}" \
      >>"$logfile" 2>&1; then
      echo "[!] WARNING: fetch of ${CGW_REMOTE}/${target_branch} failed -- behind-remote check may use stale data" | tee -a "$logfile"
      state_known=0
    fi
  fi

  local behind="0"
  if [[ ${remote_branch_exists} -eq 1 ]] && [[ ${state_known} -eq 1 ]]; then
    if ! behind=$(cgw_rev_count "${target_branch}" "${CGW_REMOTE}/${target_branch}"); then
      echo "[!] WARNING: cannot determine commits behind ${CGW_REMOTE}/${target_branch} (rev-list failed)" | tee -a "$logfile"
      state_known=0
      behind="0"
    fi
  fi

  if [[ ${remote_branch_exists} -eq 1 ]] && [[ ${state_known} -eq 0 ]]; then
    # Remote state is genuinely unverifiable -- not "diverged as expected from
    # a rebase" (see below), but "we don't know". Confirm even under --force:
    # the lease it would otherwise rely on can't be trusted either.
    echo "  Cannot verify remote state before pushing." | tee -a "$logfile"
    if ! cgw_confirm "Push anyway without a verified remote state?" --non-interactive abort; then
      echo "  Aborted" | tee -a "$logfile"
      log_section_end "REMOTE CHECK" "$logfile" "1"
      exit 1
    fi
  elif [[ "${behind}" -gt 0 ]]; then
    echo "[!] WARNING: Local branch is ${behind} commit(s) behind ${CGW_REMOTE}/${target_branch}" | tee -a "$logfile"
    echo "  A normal push may fail or overwrite remote changes." | tee -a "$logfile"
    echo "  Consider: ./scripts/git/sync_branches.sh" | tee -a "$logfile"
    if [[ ${force_push} -eq 0 ]]; then
      # Under --force this is the expected state after any rebase/amend (old
      # SHAs become unreachable from the rewritten history) -- not a hazard.
      # The force-with-lease guard in [5/5] is what verifies the remote
      # actually still matches what we just fetched.
      if ! cgw_confirm "Continue push anyway?" --non-interactive abort; then
        echo "  Aborted" | tee -a "$logfile"
        log_section_end "REMOTE CHECK" "$logfile" "1"
        exit 1
      fi
    fi
  fi

  log_section_end "REMOTE CHECK" "$logfile" "0"
  echo "" | tee -a "$logfile"

  # [3/5] Optional pre-push lint check
  if [[ ${skip_lint} -eq 0 ]] && [[ -n "${CGW_LINT_CMD}${CGW_FORMAT_CMD}${CGW_MARKDOWNLINT_CMD}" ]]; then
    log_section_start "PRE-PUSH LINT CHECK" "$logfile"
    echo "Running pre-push lint check..." | tee -a "$logfile"
    local lint_args=()
    [[ ${skip_md_lint} -eq 1 ]] && lint_args+=("--skip-md-lint")
    [[ ${no_venv} -eq 1 ]] && lint_args+=("--no-venv")
    if bash "${SCRIPT_DIR}/check_lint.sh" "${lint_args[@]}" >>"$logfile" 2>&1; then
      echo "[OK] Lint check passed" | tee -a "$logfile"
      log_section_end "PRE-PUSH LINT CHECK" "$logfile" "0"
    else
      echo "[!] Lint check failed" | tee -a "$logfile"
      log_section_end "PRE-PUSH LINT CHECK" "$logfile" "1"
      echo "  Run ./scripts/git/fix_lint.sh to fix issues, or use --skip-lint to bypass" | tee -a "$logfile"
      if ! cgw_confirm "Push anyway despite lint errors?" --non-interactive abort; then
        exit 1
      fi
    fi
    echo "" | tee -a "$logfile"
  fi

  # [4/5] Show what will be pushed
  echo "[4/5] Commits to be pushed:" | tee -a "$logfile"
  local ahead
  ahead=$(cgw_rev_count "${CGW_REMOTE}/${target_branch}" "${target_branch}" || echo "unknown")
  echo "  Local ahead of ${CGW_REMOTE}/${target_branch}: ${ahead} commit(s)" | tee -a "$logfile"
  if [[ "${ahead}" != "0" ]] && [[ "${ahead}" != "unknown" ]]; then
    git log "${CGW_REMOTE}/${target_branch}..${target_branch}" --oneline 2>/dev/null | tee -a "$logfile" || true
  fi
  echo "" | tee -a "$logfile"

  if [[ ${dry_run} -eq 1 ]]; then
    echo "=== DRY RUN -- no push performed ===" | tee -a "$logfile"
    echo "Would push: ${target_branch} -> ${CGW_REMOTE}/${target_branch}" | tee -a "$logfile"
    if [[ ${force_push} -eq 1 ]]; then
      if [[ ${remote_branch_exists} -eq 0 ]]; then
        echo "Would push as a new branch on ${CGW_REMOTE} (no force-with-lease needed)" | tee -a "$logfile"
      else
        local dry_lease_sha
        dry_lease_sha=$(git rev-parse --verify --quiet "refs/remotes/${CGW_REMOTE}/${target_branch}" 2>/dev/null) || dry_lease_sha=""
        if [[ -n "${dry_lease_sha}" ]]; then
          echo "Would use: --force-with-lease=refs/heads/${target_branch}:${dry_lease_sha}" | tee -a "$logfile"
        else
          echo "Would use: --force-with-lease (unable to resolve a lease value -- push would fail closed)" | tee -a "$logfile"
        fi
      fi
    fi
    exit 0
  fi

  # [5/5] Execute push
  log_section_start "GIT PUSH" "$logfile"

  local push_flags=()
  push_flags+=("${CGW_REMOTE}" "${target_branch}")
  if [[ ${force_push} -eq 1 ]]; then
    if [[ ${remote_branch_exists} -eq 0 ]]; then
      echo "Branch does not exist on ${CGW_REMOTE} yet -- pushing without a force-with-lease guard (nothing to clobber)" | tee -a "$logfile"
    else
      # Bare --force-with-lease derives its expected value from the local
      # remote-tracking ref, resolved via the remote's configured fetch
      # refspec -- NOT by checking whether the ref simply exists. Under a
      # narrowed/single-branch refspec that resolution silently fails and git
      # rejects with "stale info" even when the remote is perfectly in sync
      # (see the REMOTE CHECK fetch above, which populates this same ref via
      # an explicit refspec regardless of what's configured). Passing the
      # lease explicitly is the only form documented to work without relying
      # on that resolution.
      local lease_sha
      lease_sha=$(git rev-parse --verify --quiet "refs/remotes/${CGW_REMOTE}/${target_branch}" 2>/dev/null) || lease_sha=""
      if [[ -z "${lease_sha}" ]]; then
        err_tee "[FAIL] Cannot establish a force-push lease: refs/remotes/${CGW_REMOTE}/${target_branch} is unresolvable even after fetch"
        log_section_end "GIT PUSH" "$logfile" "1"
        exit 1
      fi
      push_flags+=("--force-with-lease=refs/heads/${target_branch}:${lease_sha}")
      echo "Using --force-with-lease=refs/heads/${target_branch}:${lease_sha} (explicit lease; safer than bare --force-with-lease)" | tee -a "$logfile"
    fi
  fi

  if run_git_with_logging "GIT PUSH" "$logfile" push "${push_flags[@]}"; then
    log_section_end "GIT PUSH" "$logfile" "0"
    echo "" | tee -a "$logfile"
    {
      echo "========================================"
      echo "[PUSH SUMMARY]"
      echo "========================================"
    } | tee -a "$logfile"
    echo "[OK] PUSH SUCCESSFUL" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    echo "  Branch: ${target_branch} -> ${CGW_REMOTE}/${target_branch}" | tee -a "$logfile"
    echo "  Commits pushed: ${ahead}" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    {
      echo ""
      echo "End Time: $(date)"
    } | tee -a "$logfile"
    echo "Full log: $logfile"
  else
    log_section_end "GIT PUSH" "$logfile" "1"
    echo "" | tee -a "$logfile"
    err_tee "[FAIL] Push failed"
    echo "" | tee -a "$logfile"
    echo "Common causes:" | tee -a "$logfile"
    echo "  - Remote has new commits: ./scripts/git/sync_branches.sh" | tee -a "$logfile"
    echo "  - Auth error: check SSH key or token" | tee -a "$logfile"
    echo "  - Branch protection: push may require a PR" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    echo "Full log: $logfile"
    exit 1
  fi
}

main "$@"
