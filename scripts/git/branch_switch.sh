#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Alexander Korneev
# SPDX-License-Identifier: MIT
# branch_switch.sh - Create a branch or switch branches in the CURRENT worktree
# Purpose: Wraps `git switch` so creating or changing a branch in place follows the
#          same guarded, logged pattern as other CGW scripts. Uncommitted work is
#          carried over (git's default); the script never forces the switch.
#          For a branch in a NEW worktree use worktree_manage.sh add instead.
# Usage: ./scripts/git/branch_switch.sh [-c] <branch> [<base>] [OPTIONS]
#
# Globals:
#   SCRIPT_DIR   - Directory containing this script
#   PROJECT_ROOT - Auto-detected git repo root (set by _config.sh)
#   CGW_REMOTE   - Remote used to find <remote>/<branch> (default: origin)
#   logfile      - Set by init_logging
# Arguments:
#   <branch>           Branch to switch to, or to create with -c
#   <base>             Start point for a new branch (only with -c; default HEAD)
#   -c, --create       Create <branch> and switch to it
#   --dry-run          Print the resolved `git switch` command without running it
#   --non-interactive  Accept all defaults, no prompts
#   -h, --help         Show help
# Returns:
#   0 on success, dry-run preview, already-on-branch or cancel; 1 on refusal or failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"
ensure_no_stale_index_lock || exit 1

# _bs_active_op
#   Prints the name of the first in-progress operation sentinel and returns 0;
#   returns 1 when none. Uses `git rev-parse --git-path` so it is worktree-safe.
_bs_active_op() {
  local sentinel path
  for sentinel in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    path="$(git rev-parse --git-path "${sentinel}" 2>/dev/null)" || continue
    if [[ -e "${path}" ]]; then
      echo "${sentinel}"
      return 0
    fi
  done
  return 1
}

# _bs_other_worktree <branch>
#   Prints the path of ANOTHER worktree that has <branch> checked out and returns 0;
#   returns 1 when no other worktree holds it.
_bs_other_worktree() {
  local branch="$1" here wt_path="" line
  here="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  while IFS= read -r line; do
    case "${line}" in
      "worktree "*) wt_path="${line#worktree }" ;;
      "branch refs/heads/${branch}")
        # -ef compares the directories themselves, so a case or 8.3 short-name difference
        # between the two path spellings cannot make the current worktree look foreign.
        if [[ "${wt_path}" != "${here}" ]] && ! [[ "${wt_path}" -ef "${here}" ]]; then
          echo "${wt_path}"
          return 0
        fi
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  return 1
}

# _bs_log_result <text>
#   Writes the outcome and an end time to the log, so a run that ends early (dry run,
#   cancel, already on the branch) is not left looking unfinished.
_bs_log_result() {
  {
    echo "Result: $1"
    echo "End Time: $(date)"
  } >>"$logfile"
}

# _bs_report_carried_changes
#   Lists uncommitted tracked changes that will travel with the switch and warns about
#   skip-worktree / assume-unchanged paths among them (git can switch past those silently).
_bs_report_carried_changes() {
  local dirty sw_files p
  dirty="$(cgw_tree_dirty_paths)"
  [[ -z "${dirty}" ]] && return 0

  echo "[INFO] Uncommitted changes are carried over to the target branch:" | tee -a "$logfile"
  while IFS= read -r p; do
    [[ -n "${p}" ]] && echo "         ${p}" | tee -a "$logfile"
  done <<<"${dirty}"

  sw_files="$(git ls-files -v 2>/dev/null | grep '^[a-zS]' | cut -c3-)"
  [[ -z "${sw_files}" ]] && return 0
  while IFS= read -r p; do
    if [[ -n "${p}" ]] && grep -qxF -- "${p}" <<<"${sw_files}"; then
      echo "[WARN] ${p} is marked skip-worktree/assume-unchanged: git can overwrite or keep it silently on a switch" | tee -a "$logfile"
    fi
  done <<<"${dirty}"
}

main() {
  local branch=""
  local base=""
  local create=0
  local dry_run=0

  # Auto-detect non-interactive mode when no TTY (matches pr_checkout.sh)
  [[ ! -t 0 ]] && CGW_NON_INTERACTIVE=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        echo "Usage: ./scripts/git/branch_switch.sh [-c] <branch> [<base>] [OPTIONS]"
        echo ""
        echo "Create a branch, or switch to one, in the current worktree (wraps 'git switch')."
        echo "Uncommitted changes are carried over; the switch is never forced. For a branch in a"
        echo "new worktree use worktree_manage.sh add."
        echo ""
        echo "Options:"
        echo "  -c, --create       Create <branch> from <base> (default HEAD) and switch to it"
        echo "  --dry-run          Print the resolved command without running it"
        echo "  --non-interactive  Accept all defaults, no prompts"
        echo "  -h, --help         Show this help"
        echo ""
        echo "Without -c, <branch> must exist locally, or as <remote>/<branch> (a tracking branch"
        echo "is then created)."
        echo ""
        echo "Examples:"
        echo "  ./scripts/git/branch_switch.sh -c feat/new-thing"
        echo "  ./scripts/git/branch_switch.sh -c fix/bug-12 origin/development"
        echo "  ./scripts/git/branch_switch.sh development"
        echo ""
        echo "If git refuses because a change would be overwritten, stash first:"
        echo "  ./scripts/git/stash_work.sh push"
        exit 0
        ;;
      -c | --create) create=1 ;;
      --dry-run) dry_run=1 ;;
      --non-interactive) CGW_NON_INTERACTIVE=1 ;;
      -*)
        err "Unknown flag: $1"
        exit 1
        ;;
      *)
        if [[ -z "${branch}" ]]; then
          branch="$1"
        elif [[ -z "${base}" ]]; then
          base="$1"
        else
          err "Unexpected argument: $1"
          exit 1
        fi
        ;;
    esac
    shift
  done

  if [[ -z "${branch}" ]]; then
    err "Branch name required: branch_switch.sh [-c] <branch> [<base>]"
    exit 1
  fi
  if [[ -n "${base}" && ${create} -eq 0 ]]; then
    err "A base ref only applies to a new branch: use -c ${branch} ${base}"
    exit 1
  fi

  init_logging "branch_switch"

  {
    echo "========================================="
    echo "Branch Switch Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Branch: ${branch}"
  } >"$logfile"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  echo "=== Branch Switch ===" | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  # [1/3] Preconditions
  log_section_start "PRECONDITIONS" "$logfile"

  local active_op
  if active_op="$(_bs_active_op)"; then
    err "A git operation is in progress (${active_op}) -- finish or abort it before changing branches"
    log_section_end "PRECONDITIONS" "$logfile" "1"
    exit 1
  fi

  local remote="${CGW_REMOTE:-origin}"
  local current
  current="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
  local -a git_args=()
  local summary=""

  # Validate the name in both modes: it rejects HEAD, which would otherwise match the
  # symbolic ref refs/remotes/<remote>/HEAD below. `git check-ref-format --branch` also
  # expands @{-N}; reject that form explicitly.
  if [[ "${branch}" == *"@{"* ]] || ! git check-ref-format --branch "${branch}" >/dev/null 2>&1; then
    err "Invalid branch name: ${branch}"
    log_section_end "PRECONDITIONS" "$logfile" "1"
    exit 1
  fi

  if [[ ${create} -eq 1 ]]; then
    if git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null 2>&1; then
      err "Branch '${branch}' already exists -- switch to it without -c"
      log_section_end "PRECONDITIONS" "$logfile" "1"
      exit 1
    fi
    if [[ -n "${base}" ]]; then
      if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
        err "Invalid base ref: ${base}"
        log_section_end "PRECONDITIONS" "$logfile" "1"
        exit 1
      fi
      if [[ "${base}" == "${remote}/${branch}" || "${base}" == "refs/remotes/${remote}/${branch}" ]]; then
        # The base is this branch's own remote counterpart: tracking it is correct.
        git_args=(--track -c "${branch}" "${base}")
        summary="${branch} (new, from ${base}, tracking ${remote}/${branch})"
      else
        # --no-track: the base is where the branch starts, not where it pushes.
        git_args=(--no-track -c "${branch}" "${base}")
        summary="${branch} (new, from ${base}, no upstream until first push)"
      fi
    else
      # No base: always start at HEAD, like `git switch -c`. A leftover or newer
      # <remote>/<branch> is NOT used silently; the warning names the explicit forms.
      git_args=(--no-track -c "${branch}")
      if [[ -z "${current}" ]]; then
        summary="${branch} (new, from detached HEAD $(git rev-parse --short HEAD 2>/dev/null), no upstream until first push)"
      else
        summary="${branch} (new, from ${current}, no upstream until first push)"
      fi
      if git rev-parse --verify --quiet "refs/remotes/${remote}/${branch}" >/dev/null 2>&1; then
        echo "[WARN] ${remote}/${branch} already exists; the new branch starts at HEAD, not at it." | tee -a "$logfile"
        echo "       To start from it: branch_switch.sh -c ${branch} ${remote}/${branch}  (or drop -c to track it)" | tee -a "$logfile"
      fi
    fi
  else
    if [[ "${branch}" == "${current}" ]]; then
      echo "[OK] Already on '${branch}'" | tee -a "$logfile"
      log_section_end "PRECONDITIONS" "$logfile" "0"
      _bs_log_result "already on ${branch}, nothing to do"
      exit 0
    fi
    if git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null 2>&1; then
      git_args=("${branch}")
      summary="${branch}"
    elif git rev-parse --verify --quiet "refs/remotes/${remote}/${branch}" >/dev/null 2>&1; then
      git_args=(--track -c "${branch}" "${remote}/${branch}")
      summary="${branch} (new local branch, tracking ${remote}/${branch})"
    else
      err "No branch '${branch}' locally or on ${remote} -- create it with: branch_switch.sh -c ${branch}"
      log_section_end "PRECONDITIONS" "$logfile" "1"
      exit 1
    fi
  fi

  # Only a switch can target a branch another worktree holds: with -c the name is new
  # (an existing one was refused above), so no worktree can have it.
  local other_wt
  if [[ ${create} -eq 0 ]] && other_wt="$(_bs_other_worktree "${branch}")"; then
    err "Branch '${branch}' is already checked out in another worktree: ${other_wt}"
    log_section_end "PRECONDITIONS" "$logfile" "1"
    exit 1
  fi

  echo "  From:   ${current:-(detached HEAD)}" | tee -a "$logfile"
  echo "  Target: ${summary}" | tee -a "$logfile"
  echo "" | tee -a "$logfile"
  _bs_report_carried_changes
  log_section_end "PRECONDITIONS" "$logfile" "0"
  echo "" | tee -a "$logfile"

  if [[ ${dry_run} -eq 1 ]]; then
    echo "=== DRY RUN -- branch not changed ===" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    echo "Would run: git switch ${git_args[*]}" | tee -a "$logfile"
    _bs_log_result "dry run, branch not changed"
    exit 0
  fi

  if ! cgw_confirm "Switch to ${summary}?" --default yes --non-interactive accept; then
    echo "Cancelled" | tee -a "$logfile"
    _bs_log_result "cancelled by the user, branch not changed"
    exit 0
  fi

  # [2/3] Switch (never --force / --discard-changes / --merge)
  log_section_start "GIT SWITCH" "$logfile"
  if git switch "${git_args[@]}" 2>&1 | tee -a "$logfile"; then
    log_section_end "GIT SWITCH" "$logfile" "0"
    echo "" | tee -a "$logfile"
    echo "[OK] On branch $(git symbolic-ref -q --short HEAD 2>/dev/null || echo '(detached HEAD)')" | tee -a "$logfile"
    _bs_log_result "switched to ${summary}"
    echo "Full log: $logfile"
  else
    log_section_end "GIT SWITCH" "$logfile" "1"
    err "Switch failed -- check log: ${logfile}"
    echo "  If a local change would be overwritten, stash first: ./scripts/git/stash_work.sh push" | tee -a "$logfile"
    _bs_log_result "git switch failed, branch not changed"
    exit 1
  fi
}

main "$@"
