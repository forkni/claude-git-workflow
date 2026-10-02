#!/usr/bin/env bash
# merge_pr.sh - Merge a GitHub PR with a merge commit, optionally retargeting stacked PRs
# Purpose: Wraps `gh pr merge` so the PR-mode promotion (CGW_MERGE_MODE="pr") has a guarded,
#          logged merge step. Defaults to a merge commit (--merge): the merged feature stays
#          one revertable unit (rollback_merge.sh --revert). --squash/--rebase flatten it
#          (Git for Teams p.112) and need an explicit acknowledgement.
# Usage: ./scripts/git/merge_pr.sh <PR-number> [OPTIONS]
#
# Globals:
#   SCRIPT_DIR   - Directory containing this script
#   PROJECT_ROOT - Auto-detected git repo root (set by _config.sh)
#   CGW_REMOTE   - Remote whose github.com owner/repo is passed to gh as --repo
#   logfile      - Set by init_logging
# Arguments:
#   <PR-number>        PR number to merge (or use --pr <N>)
#   --pr <N>           Same as positional PR number
#   --squash           Squash-merge instead of a merge commit (needs --allow-non-merge
#                      when non-interactive)
#   --rebase           Rebase-merge instead of a merge commit (same rule as --squash)
#   --allow-non-merge  Acknowledge that --squash/--rebase make the PR non-revertable as a unit
#   --retarget <M>     After merging, retarget stacked PR #M (whose base is this PR's head
#                      branch) onto this PR's base branch. Repeatable.
#   --delete-branch    Delete this PR's head branch after merge and retarget (never by default)
#   --dry-run          Validate and print the gh commands without merging
#   --non-interactive  Accept all defaults, no prompts
#   -h, --help         Show help
# Returns:
#   0 on success (or dry-run preview), 1 on failure
#
# Prerequisites:
#   gh CLI installed and authenticated (gh auth login)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"
ensure_no_stale_index_lock || exit 1

# _pr_view <number> <json-field> <jq-expr>
# Echoes one field of a PR via gh's built-in --jq (no external jq needed).
_pr_view() {
  gh pr view "$1" --repo "${pr_repo}" --json "$2" --jq "$3" 2>/dev/null
}

main() {
  local pr_number=""
  local method="merge"
  local allow_non_merge=0
  local retarget=()
  local delete_branch=0
  local dry_run=0
  local non_interactive=0

  # Auto-detect non-interactive mode when no TTY (matches create_pr.sh)
  [[ ! -t 0 ]] && CGW_NON_INTERACTIVE=1
  [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        echo "Usage: ./scripts/git/merge_pr.sh <PR-number> [OPTIONS]"
        echo ""
        echo "Merge a GitHub PR with a merge commit (wraps 'gh pr merge --merge')."
        echo ""
        echo "Options:"
        echo "  --pr <N>           PR number to merge (or pass it positionally)"
        echo "  --squash           Squash-merge instead (flattens the PR; see --allow-non-merge)"
        echo "  --rebase           Rebase-merge instead (flattens the PR; see --allow-non-merge)"
        echo "  --allow-non-merge  Required with --squash/--rebase when non-interactive"
        echo "  --retarget <M>     After merging, retarget stacked PR #M onto this PR's base"
        echo "                     branch (its base must be this PR's head). Repeatable."
        echo "  --delete-branch    Delete the head branch after merge and retarget"
        echo "                     (never deleted by default)"
        echo "  --dry-run          Validate and print the gh commands without merging"
        echo "  --non-interactive  Accept all defaults, no prompts"
        echo "  -h, --help         Show this help"
        echo ""
        echo "Examples:"
        echo "  ./scripts/git/merge_pr.sh 42"
        echo "  ./scripts/git/merge_pr.sh 42 --retarget 43 --retarget 44"
        echo "  ./scripts/git/merge_pr.sh 42 --dry-run"
        echo ""
        echo "Notes:"
        echo "  A merge commit keeps the feature revertable as one unit. After a merge, undo with:"
        echo "    ./scripts/git/rollback_merge.sh --revert --target <merge-sha>"
        echo "  Passes gh an explicit --repo resolved from \${CGW_REMOTE}'s URL, so a fork remote"
        echo "  targets itself instead of gh's default (the fork's parent repo)."
        echo ""
        echo "Prerequisites:"
        echo "  gh CLI installed and authenticated (gh auth login)"
        exit 0
        ;;
      --pr)
        pr_number="${2:-}"
        if [[ -z "${pr_number}" ]]; then
          err "--pr requires a PR number"
          exit 1
        fi
        shift
        ;;
      --squash | --rebase)
        if [[ "${method}" != "merge" && "${method}" != "${1#--}" ]]; then
          err "--squash and --rebase are mutually exclusive"
          exit 1
        fi
        method="${1#--}"
        ;;
      --allow-non-merge) allow_non_merge=1 ;;
      --retarget)
        if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
          err "--retarget requires a PR number"
          exit 1
        fi
        retarget+=("$2")
        shift
        ;;
      --delete-branch) delete_branch=1 ;;
      --dry-run) dry_run=1 ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        ;;
      -*)
        err "Unknown flag: $1"
        exit 1
        ;;
      *)
        if [[ -z "${pr_number}" ]]; then
          pr_number="$1"
        else
          err "Unexpected argument: $1"
          exit 1
        fi
        ;;
    esac
    shift
  done

  if [[ -z "${pr_number}" ]]; then
    err "PR number required (positional or --pr <N>)"
    exit 1
  fi

  if ! [[ "${pr_number}" =~ ^[0-9]+$ ]]; then
    err "Invalid PR number: ${pr_number}"
    exit 1
  fi

  local m
  for m in "${retarget[@]}"; do
    if [[ "${m}" == "${pr_number}" ]]; then
      err "--retarget ${m} is the PR being merged"
      exit 1
    fi
  done

  # --squash/--rebase flatten the PR into commits that can no longer be reverted as one unit.
  if [[ "${method}" != "merge" && ${non_interactive} -eq 1 && ${allow_non_merge} -eq 0 ]]; then
    err "--${method} flattens the PR (it cannot be reverted as a unit); non-interactive mode"
    err "requires --allow-non-merge to confirm. Omit --${method} for a merge commit."
    exit 1
  fi

  init_logging "merge_pr"

  {
    echo "========================================="
    echo "PR Merge Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "PR: #${pr_number}"
  } >"$logfile"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  echo "=== PR Merge ===" | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  # [1/4] Prerequisites
  log_section_start "PREREQUISITES" "$logfile"
  if ! cgw_require_gh; then
    log_section_end "PREREQUISITES" "$logfile" "1"
    exit 1
  fi
  echo "[OK] gh CLI installed and authenticated" | tee -a "$logfile"

  # Explicit --repo from CGW_REMOTE's URL: without it gh may resolve a fork's parent repo.
  pr_repo=""
  if pr_repo=$(cgw_remote_owner_repo "${CGW_REMOTE}"); then
    echo "Repo: ${pr_repo}" | tee -a "$logfile"
  else
    err_tee "[ERROR] Could not determine ${CGW_REMOTE}'s owner/repo from its configured URL."
    err_tee "[ERROR] Refusing to run 'gh pr merge' without an explicit --repo (a fork would default to its parent)."
    err_tee "[ERROR] Fix: run 'git remote -v' and confirm ${CGW_REMOTE} is a github.com SSH/HTTPS URL."
    log_section_end "PREREQUISITES" "$logfile" "1"
    exit 1
  fi
  log_section_end "PREREQUISITES" "$logfile" "0"
  echo "" | tee -a "$logfile"

  # [2/4] Validate the PR (and any stacked PRs) before touching anything
  log_section_start "VALIDATE PR" "$logfile"
  local state base_branch head_branch
  state=$(_pr_view "${pr_number}" state .state) || state=""
  base_branch=$(_pr_view "${pr_number}" baseRefName .baseRefName) || base_branch=""
  head_branch=$(_pr_view "${pr_number}" headRefName .headRefName) || head_branch=""
  if [[ -z "${state}" || -z "${base_branch}" || -z "${head_branch}" ]]; then
    err_tee "[ERROR] Could not read PR #${pr_number} from ${pr_repo} (does it exist?)"
    log_section_end "VALIDATE PR" "$logfile" "1"
    exit 1
  fi
  if [[ "${state}" != "OPEN" ]]; then
    err_tee "[ERROR] PR #${pr_number} is ${state}, not OPEN -- nothing to merge"
    log_section_end "VALIDATE PR" "$logfile" "1"
    exit 1
  fi
  echo "[OK] PR #${pr_number}: ${head_branch} -> ${base_branch} (OPEN)" | tee -a "$logfile"

  for m in "${retarget[@]}"; do
    local m_state m_base
    m_state=$(_pr_view "${m}" state .state) || m_state=""
    m_base=$(_pr_view "${m}" baseRefName .baseRefName) || m_base=""
    if [[ "${m_state}" != "OPEN" ]]; then
      err_tee "[ERROR] Stacked PR #${m} is '${m_state:-unreadable}', not OPEN -- cannot retarget"
      log_section_end "VALIDATE PR" "$logfile" "1"
      exit 1
    fi
    if [[ "${m_base}" != "${head_branch}" ]]; then
      err_tee "[ERROR] Stacked PR #${m} has base '${m_base}', expected '${head_branch}' (PR #${pr_number}'s head) -- not stacked on this PR"
      log_section_end "VALIDATE PR" "$logfile" "1"
      exit 1
    fi
    echo "[OK] Stacked PR #${m}: base ${m_base} -> will retarget to ${base_branch}" | tee -a "$logfile"
  done

  if [[ ${delete_branch} -eq 1 && ! "${head_branch}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    err_tee "[ERROR] Refusing to delete head branch with unusual name: ${head_branch}"
    log_section_end "VALIDATE PR" "$logfile" "1"
    exit 1
  fi
  # The head branch lives in the PR's head repository (a fork for cross-repository PRs), which
  # is not necessarily pr_repo. Resolve it before merging so a bad lookup refuses up front.
  local head_repo=""
  if [[ ${delete_branch} -eq 1 ]]; then
    head_repo=$(_pr_view "${pr_number}" headRepository,headRepositoryOwner '(.headRepositoryOwner.login) + "/" + (.headRepository.name)') || head_repo=""
    if [[ ! "${head_repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      err_tee "[ERROR] Cannot determine PR #${pr_number}'s head repository (deleted fork?) -- refusing --delete-branch"
      log_section_end "VALIDATE PR" "$logfile" "1"
      exit 1
    fi
  fi
  log_section_end "VALIDATE PR" "$logfile" "0"
  echo "" | tee -a "$logfile"

  local merge_args=("${pr_number}" --repo "${pr_repo}" "--${method}")

  if [[ ${dry_run} -eq 1 ]]; then
    echo "=== DRY RUN -- nothing merged ===" | tee -a "$logfile"
    echo "" | tee -a "$logfile"
    echo "Would run: gh pr merge ${merge_args[*]}" | tee -a "$logfile"
    for m in "${retarget[@]}"; do
      echo "Would run: gh pr edit ${m} --repo ${pr_repo} --base ${base_branch}" | tee -a "$logfile"
    done
    [[ ${delete_branch} -eq 1 ]] &&
      echo "Would delete branch: ${head_branch} in ${head_repo}" | tee -a "$logfile"
    exit 0
  fi

  if [[ "${method}" != "merge" ]]; then
    echo "[WARN] --${method} flattens PR #${pr_number} into commits that can't be reverted as one unit." | tee -a "$logfile"
    echo "       A merge commit would stay revertable with rollback_merge.sh --revert." | tee -a "$logfile"
  fi

  # Interactive confirmation: merging is outward-facing and not undone by a local reset.
  if [[ ${non_interactive} -eq 0 ]]; then
    local default_answer="yes"
    [[ "${method}" != "merge" ]] && default_answer="no"
    if ! cgw_confirm "Merge PR #${pr_number} into ${base_branch} (--${method})?" --default "${default_answer}"; then
      echo "Cancelled"
      exit 0
    fi
  fi

  # Recovery point: the merge happens on the remote, so tag the base branch's current remote tip.
  # The merge commit's first parent will be exactly this commit (rollback_merge.sh's HEAD^1 guard).
  if git fetch --quiet "${CGW_REMOTE}" "${base_branch}" >>"$logfile" 2>&1; then
    cgw_create_backup_tag merge "refs/remotes/${CGW_REMOTE}/${base_branch}"
  else
    err_tee "[!] Could not fetch ${CGW_REMOTE}/${base_branch} -- no pre-merge backup tag created (continuing)"
  fi

  # [3/4] Merge
  log_section_start "GH PR MERGE" "$logfile"
  if gh pr merge "${merge_args[@]}" 2>&1 | tee -a "$logfile"; then
    log_section_end "GH PR MERGE" "$logfile" "0"
  else
    log_section_end "GH PR MERGE" "$logfile" "1"
    err "gh pr merge failed -- check log: ${logfile}"
    exit 1
  fi

  # A merge queue or auto-merge makes gh exit 0 before the PR is actually merged: re-read the state
  # and, if it is not MERGED, leave the retarget/delete (which assume a merged PR) to the user.
  local post_state
  post_state=$(_pr_view "${pr_number}" state .state) || post_state=""
  if [[ "${post_state}" != "MERGED" ]]; then
    echo "[!] PR #${pr_number} is ${post_state:-in an unknown state}, not merged yet (merge queue or auto-merge pending)" | tee -a "$logfile"
    echo "    Skipping --retarget and --delete-branch; rerun them once the PR shows MERGED." | tee -a "$logfile"
    echo "Full log: $logfile"
    exit 0
  fi
  echo "[OK] Merged PR #${pr_number} into ${base_branch} (--${method})" | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  # [4/4] Retarget stacked PRs, then optionally delete the head branch.
  # Order matters: deleting the head first would auto-close PRs still based on it.
  local failed=0
  if [[ ${#retarget[@]} -gt 0 ]]; then
    log_section_start "RETARGET STACKED PRS" "$logfile"
    for m in "${retarget[@]}"; do
      if gh pr edit "${m}" --repo "${pr_repo}" --base "${base_branch}" 2>&1 | tee -a "$logfile"; then
        echo "[OK] Retargeted PR #${m} onto ${base_branch}" | tee -a "$logfile"
      else
        err_tee "[ERROR] Failed to retarget PR #${m} -- PR #${pr_number} is already merged; retarget manually:"
        err_tee "        gh pr edit ${m} --repo ${pr_repo} --base ${base_branch}"
        failed=1
      fi
    done
    log_section_end "RETARGET STACKED PRS" "$logfile" "${failed}"
  fi

  if [[ ${delete_branch} -eq 1 ]]; then
    if [[ ${failed} -eq 1 ]]; then
      err_tee "[WARN] Skipping --delete-branch: a stacked PR could still be based on ${head_branch}"
    else
      log_section_start "DELETE HEAD BRANCH" "$logfile"
      # head_repo, not pr_repo: for a cross-repository PR the branch lives in the head repository.
      if gh api --method DELETE "repos/${head_repo}/git/refs/heads/${head_branch}" 2>&1 | tee -a "$logfile"; then
        echo "[OK] Deleted remote branch ${head_branch} (${head_repo})" | tee -a "$logfile"
        log_section_end "DELETE HEAD BRANCH" "$logfile" "0"
      else
        err_tee "[ERROR] Could not delete remote branch ${head_branch} in ${head_repo} (already gone, or no permission)"
        failed=1
        log_section_end "DELETE HEAD BRANCH" "$logfile" "1"
      fi
    fi
  fi

  local merge_sha
  merge_sha=$(_pr_view "${pr_number}" mergeCommit .mergeCommit.oid) || merge_sha=""
  echo "" | tee -a "$logfile"
  if [[ -n "${merge_sha}" && "${merge_sha}" != "null" ]]; then
    echo "Merge commit: ${merge_sha}" | tee -a "$logfile"
    if [[ "${method}" == "merge" ]]; then
      echo "Undo (history-preserving): ./scripts/git/rollback_merge.sh --revert --target ${merge_sha}" | tee -a "$logfile"
    fi
  fi
  echo "Full log: $logfile"
  [[ ${failed} -eq 0 ]]
}

main "$@"
