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
#   --retarget-all     Retarget every open PR whose base is this PR's head branch
#   --delete-branch    Delete this PR's head branch after merge and retarget (never by default).
#                      Refused while an open PR based on the head branch is not retargeted:
#                      deleting a PR's base branch through the API closes that PR.
#   --allow-local-changes  Merge although the local checkout of the head or base branch has
#                      uncommitted changes, or the local head branch has unpushed commits
#   --wait-checks      Wait for the PR head to match the pushed branch, for checks to appear on
#                      it, and for pending checks (gh pr checks --watch). The merge is pinned to
#                      the verified head (gh pr merge --match-head-commit).
#   --skip-checks      Merge without requiring green PR checks (logged as a warning)
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

# _pr_view <number> <json-field> <jq-expr> -- cgw_pr_view (_common.sh) against this repo
_pr_view() {
  cgw_pr_view "${pr_repo}" "$@"
}

main() {
  local pr_number=""
  local method="merge"
  local allow_non_merge=0
  local retarget=()
  local retarget_all=0
  local delete_branch=0
  local allow_local=0
  local wait_checks=0
  local skip_checks=0
  local dry_run=0
  local non_interactive=0

  # Auto-detect non-interactive mode when no TTY (matches create_pr.sh)
  [[ ! -t 0 ]] && CGW_NON_INTERACTIVE=1
  [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1

  while [[ ${#} -gt 0 ]]; do
    case "${1}" in
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
        echo "  --retarget-all     Retarget every open PR based on this PR's head branch"
        echo "  --delete-branch    Delete the head branch after merge and retarget"
        echo "                     (never deleted by default; refused while an open PR is still"
        echo "                     based on it -- deleting a PR's base closes that PR)"
        echo "  --allow-local-changes"
        echo "                     Merge although the head/base checkout has uncommitted changes"
        echo "                     or the local head branch has unpushed commits"
        echo "  --wait-checks      Wait for the PR head to catch up with the pushed branch, for checks"
        echo "                     to appear, and for pending checks, instead of refusing"
        echo "  --skip-checks      Merge without requiring green PR checks (not recommended)"
        echo "  --dry-run          Validate and print the gh commands without merging"
        echo "  --non-interactive  Accept all defaults, no prompts"
        echo "  -h, --help         Show this help"
        echo ""
        echo "Examples:"
        echo "  ./scripts/git/merge_pr.sh 42"
        echo "  ./scripts/git/merge_pr.sh 42 --retarget 43 --retarget 44"
        echo "  ./scripts/git/merge_pr.sh 42 --retarget-all --delete-branch"
        echo "  ./scripts/git/merge_pr.sh 42 --dry-run"
        echo ""
        echo "Notes:"
        echo "  The PR's checks must be green (gh pr checks) before anything is merged; pending checks"
        echo "  refuse unless --wait-checks, failing checks always refuse unless --skip-checks."
        echo "  Checks must belong to the PR's current head: a head that lags the pushed branch is"
        echo "  refused (or waited for), a recent head with no checks refuses without --wait-checks,"
        echo "  and the merge is pinned to the verified commit (--match-head-commit)."
        echo "  Tunables: CGW_PR_CHECKS_POLL_SECONDS, CGW_PR_HEAD_SYNC_SECONDS, CGW_PR_CHECKS_APPEAR_SECONDS."
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
        if [[ -z "${2:-}" ]] || ! [[ "${2}" =~ ^[0-9]+$ ]]; then
          err "--retarget requires a PR number"
          exit 1
        fi
        retarget+=("${2}")
        shift
        ;;
      --retarget-all) retarget_all=1 ;;
      --delete-branch) delete_branch=1 ;;
      --allow-local-changes) allow_local=1 ;;
      --wait-checks) wait_checks=1 ;;
      --skip-checks) skip_checks=1 ;;
      --dry-run) dry_run=1 ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        ;;
      -*)
        err "Unknown flag: ${1}"
        exit 1
        ;;
      *)
        if [[ -z "${pr_number}" ]]; then
          pr_number="${1}"
        else
          err "Unexpected argument: ${1}"
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
  } >"${logfile}"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  echo "=== PR Merge ===" | tee -a "${logfile}"
  echo "" | tee -a "${logfile}"

  # [1/4] Prerequisites
  log_section_start "PREREQUISITES" "${logfile}"
  if ! cgw_require_gh; then
    log_section_end "PREREQUISITES" "${logfile}" "1"
    exit 1
  fi
  echo "[OK] gh CLI installed and authenticated" | tee -a "${logfile}"

  # Explicit --repo from CGW_REMOTE's URL: without it gh may resolve a fork's parent repo.
  pr_repo=""
  if pr_repo=$(cgw_remote_owner_repo "${CGW_REMOTE}"); then
    echo "Repo: ${pr_repo}" | tee -a "${logfile}"
  else
    err_tee "[ERROR] Could not determine ${CGW_REMOTE}'s owner/repo from its configured URL."
    err_tee "[ERROR] Refusing to run 'gh pr merge' without an explicit --repo (a fork would default to its parent)."
    err_tee "[ERROR] Fix: run 'git remote -v' and confirm ${CGW_REMOTE} is a github.com SSH/HTTPS URL."
    log_section_end "PREREQUISITES" "${logfile}" "1"
    exit 1
  fi
  log_section_end "PREREQUISITES" "${logfile}" "0"
  echo "" | tee -a "${logfile}"

  # [2/4] Validate the PR (and any stacked PRs) before touching anything
  log_section_start "VALIDATE PR" "${logfile}"
  local state base_branch head_branch
  state=$(_pr_view "${pr_number}" state .state) || state=""
  base_branch=$(_pr_view "${pr_number}" baseRefName .baseRefName) || base_branch=""
  head_branch=$(_pr_view "${pr_number}" headRefName .headRefName) || head_branch=""
  if [[ -z "${state}" || -z "${base_branch}" || -z "${head_branch}" ]]; then
    err_tee "[ERROR] Could not read PR #${pr_number} from ${pr_repo} (does it exist?)"
    log_section_end "VALIDATE PR" "${logfile}" "1"
    exit 1
  fi
  if [[ "${state}" != "OPEN" ]]; then
    err_tee "[ERROR] PR #${pr_number} is ${state}, not OPEN -- nothing to merge"
    log_section_end "VALIDATE PR" "${logfile}" "1"
    exit 1
  fi
  echo "[OK] PR #${pr_number}: ${head_branch} -> ${base_branch} (OPEN)" | tee -a "${logfile}"

  # Open PRs based on this PR's head branch. Deleting that branch through the API closes every
  # one of them, so each must be retargeted before --delete-branch (Pro Git p.98-99: move the
  # dependent branch before deleting its base). An unreadable list fails closed only where it
  # matters (--delete-branch / --retarget-all); otherwise it is a warning.
  local stacked=() stacked_out="" stacked_known=1
  if stacked_out=$(gh pr list --repo "${pr_repo}" --base "${head_branch}" --state open \
    --json number --jq '.[].number' 2>>"${logfile}"); then
    while IFS= read -r m; do
      [[ "${m}" =~ ^[0-9]+$ && "${m}" != "${pr_number}" ]] && stacked+=("${m}")
    done <<<"${stacked_out}"
  else
    stacked_known=0
    if [[ ${delete_branch} -eq 1 || ${retarget_all} -eq 1 ]]; then
      err_tee "[ERROR] Could not list open PRs based on ${head_branch} -- refusing --delete-branch/--retarget-all"
      err_tee "[ERROR] (deleting a PR's base branch closes that PR; check with: gh pr list --base ${head_branch})"
      log_section_end "VALIDATE PR" "${logfile}" "1"
      exit 1
    fi
    echo "[WARN] Could not list open PRs based on ${head_branch}; stacked PRs not checked" | tee -a "${logfile}"
  fi

  local s r found
  if [[ ${retarget_all} -eq 1 ]]; then
    for s in "${stacked[@]}"; do
      found=0
      for r in "${retarget[@]}"; do [[ "${r}" == "${s}" ]] && found=1; done
      [[ ${found} -eq 0 ]] && retarget+=("${s}")
    done
    [[ ${#stacked[@]} -eq 0 ]] && echo "[OK] --retarget-all: no open PR is based on ${head_branch}" | tee -a "${logfile}"
  fi

  for m in "${retarget[@]}"; do
    local m_state m_base
    m_state=$(_pr_view "${m}" state .state) || m_state=""
    m_base=$(_pr_view "${m}" baseRefName .baseRefName) || m_base=""
    if [[ "${m_state}" != "OPEN" ]]; then
      err_tee "[ERROR] Stacked PR #${m} is '${m_state:-unreadable}', not OPEN -- cannot retarget"
      log_section_end "VALIDATE PR" "${logfile}" "1"
      exit 1
    fi
    if [[ "${m_base}" != "${head_branch}" ]]; then
      err_tee "[ERROR] Stacked PR #${m} has base '${m_base}', expected '${head_branch}' (PR #${pr_number}'s head) -- not stacked on this PR"
      log_section_end "VALIDATE PR" "${logfile}" "1"
      exit 1
    fi
    echo "[OK] Stacked PR #${m}: base ${m_base} -> will retarget to ${base_branch}" | tee -a "${logfile}"
  done

  local uncovered=()
  for s in "${stacked[@]}"; do
    found=0
    for r in "${retarget[@]}"; do [[ "${r}" == "${s}" ]] && found=1; done
    [[ ${found} -eq 0 ]] && uncovered+=("${s}")
  done
  if [[ ${#uncovered[@]} -gt 0 ]]; then
    if [[ ${delete_branch} -eq 1 ]]; then
      err_tee "[ERROR] Open PR(s) #${uncovered[*]} are based on ${head_branch}; --delete-branch would close them"
      err_tee "[ERROR] Add --retarget <N> for each, or --retarget-all, or drop --delete-branch"
      log_section_end "VALIDATE PR" "${logfile}" "1"
      exit 1
    fi
    echo "[WARN] Open PR(s) #${uncovered[*]} stay based on ${head_branch} after the merge" | tee -a "${logfile}"
    echo "       Retarget them with --retarget <N> or --retarget-all" | tee -a "${logfile}"
  elif [[ ${stacked_known} -eq 1 && ${#stacked[@]} -gt 0 ]]; then
    echo "[OK] Every open PR based on ${head_branch} will be retargeted" | tee -a "${logfile}"
  fi

  # Local work guard: the merge happens on GitHub, so uncommitted changes or unpushed commits
  # on the local head branch are silently left out of it -- and --delete-branch then strands
  # them. A dirty checkout of the base branch would also block the pull that follows.
  # (Pro Git p.272: merge from a clean working directory.)
  if [[ ${allow_local} -eq 0 ]]; then
    local cur_branch local_head remote_head
    cur_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || cur_branch=""
    if [[ -n "${cur_branch}" && ("${cur_branch}" == "${head_branch}" || "${cur_branch}" == "${base_branch}") ]] &&
      ! cgw_is_tree_clean; then
      err_tee "[ERROR] The checkout of ${cur_branch} has uncommitted changes:"
      cgw_tree_dirty_paths | head -n 20 | sed 's/^/          /' | tee -a "${logfile}" >&2
      err_tee "[ERROR] Commit and push them (or stash them), or pass --allow-local-changes"
      log_section_end "VALIDATE PR" "${logfile}" "1"
      exit 1
    fi
    local_head=$(git rev-parse --verify --quiet "refs/heads/${head_branch}^{commit}") || local_head=""
    if [[ -n "${local_head}" ]]; then
      remote_head=$(git ls-remote "${CGW_REMOTE}" "refs/heads/${head_branch}" 2>>"${logfile}" | awk 'NR==1 {print $1}')
      if [[ -n "${remote_head}" && "${local_head}" != "${remote_head}" ]] &&
        ! git cat-file -e "${remote_head}^{commit}" 2>/dev/null; then
        git fetch --quiet "${CGW_REMOTE}" "refs/heads/${head_branch}" >>"${logfile}" 2>&1 || true
      fi
      if [[ -n "${remote_head}" && "${local_head}" != "${remote_head}" ]] &&
        ! git cat-file -e "${remote_head}^{commit}" 2>/dev/null; then
        echo "[WARN] Could not fetch ${CGW_REMOTE}/${head_branch}; unpushed local commits not checked" | tee -a "${logfile}"
      elif [[ -n "${remote_head}" && "${local_head}" != "${remote_head}" ]] &&
        ! git merge-base --is-ancestor "${local_head}" "${remote_head}" 2>/dev/null; then
        err_tee "[ERROR] Local ${head_branch} (${local_head:0:7}) has commits not on ${CGW_REMOTE}/${head_branch} (${remote_head:0:7})"
        err_tee "[ERROR] They would be left out of the merge. Push them first, or pass --allow-local-changes"
        log_section_end "VALIDATE PR" "${logfile}" "1"
        exit 1
      fi
    fi
  fi

  if [[ ${delete_branch} -eq 1 && ! "${head_branch}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    err_tee "[ERROR] Refusing to delete head branch with unusual name: ${head_branch}"
    log_section_end "VALIDATE PR" "${logfile}" "1"
    exit 1
  fi
  # The head branch lives in the PR's head repository (a fork for cross-repository PRs), which
  # is not necessarily pr_repo. Resolve it before merging so a bad lookup refuses up front.
  local head_repo=""
  if [[ ${delete_branch} -eq 1 ]]; then
    head_repo=$(_pr_view "${pr_number}" headRepository,headRepositoryOwner '(.headRepositoryOwner.login) + "/" + (.headRepository.name)') || head_repo=""
    if [[ ! "${head_repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      err_tee "[ERROR] Cannot determine PR #${pr_number}'s head repository (deleted fork?) -- refusing --delete-branch"
      log_section_end "VALIDATE PR" "${logfile}" "1"
      exit 1
    fi
  fi
  log_section_end "VALIDATE PR" "${logfile}" "0"
  echo "" | tee -a "${logfile}"

  # [2b/4] Required PR checks: the promotion contract merges only after CI is green.
  # gh pr checks exits 0 = all passed, 8 = pending, 1 = failing. It carries no commit SHA: it
  # reports on whatever head GitHub currently has for the PR. Right after a push that head can
  # still be the OLD commit (green checks), or the new one before any check registered ("no
  # checks reported"). So the gate (1) waits for the PR head to match the pushed branch, (2) waits
  # for checks to appear on it, and (3) pins the merge to the verified head (--match-head-commit).
  log_section_start "PR CHECKS" "${logfile}"
  local poll="${CGW_PR_CHECKS_POLL_SECONDS:-5}"
  local sync_max="${CGW_PR_HEAD_SYNC_SECONDS:-60}"
  local appear_max="${CGW_PR_CHECKS_APPEAR_SECONDS:-90}"
  local step=$((poll > 0 ? poll : 1))
  local head_sha
  head_sha=$(_pr_view "${pr_number}" headRefOid .headRefOid) || head_sha=""
  if [[ ! "${head_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    err_tee "[ERROR] Could not read PR #${pr_number}'s head commit -- refusing to merge an unidentified head"
    log_section_end "PR CHECKS" "${logfile}" "1"
    exit 1
  fi

  if [[ ${skip_checks} -eq 1 ]]; then
    echo "[WARN] --skip-checks: merging PR #${pr_number} (${head_sha:0:7}) without verifying its checks" | tee -a "${logfile}"
    log_section_end "PR CHECKS" "${logfile}" "0"
  else
    # (1) Head sync: the branch tip on the remote is what the user just pushed; a cross-repository
    # PR's head lives in a fork we can't see, so only same-repo PRs are compared.
    local expected_sha="" is_cross
    is_cross=$(_pr_view "${pr_number}" isCrossRepository .isCrossRepository) || is_cross=""
    if [[ "${is_cross}" != "true" ]]; then
      expected_sha=$(git ls-remote "${CGW_REMOTE}" "refs/heads/${head_branch}" 2>>"${logfile}" | awk 'NR==1 {print $1}')
    fi
    local waited=0
    while [[ -n "${expected_sha}" && "${head_sha}" != "${expected_sha}" ]]; do
      if [[ ${wait_checks} -eq 0 || ${waited} -ge ${sync_max} ]]; then
        err_tee "[ERROR] PR #${pr_number} head ${head_sha:0:7} has not caught up with ${CGW_REMOTE}/${head_branch} ${expected_sha:0:7} -- GitHub is still processing the push"
        err_tee "[ERROR] Rerun with --wait-checks (waits up to ${sync_max}s), or retry in a moment"
        log_section_end "PR CHECKS" "${logfile}" "1"
        exit 1
      fi
      echo "PR #${pr_number} head ${head_sha:0:7} != pushed ${expected_sha:0:7} -- waiting for GitHub (${waited}/${sync_max}s)" | tee -a "${logfile}"
      sleep "${poll}"
      waited=$((waited + step))
      head_sha=$(_pr_view "${pr_number}" headRefOid .headRefOid) || head_sha=""
      if [[ ! "${head_sha}" =~ ^[0-9a-f]{40}$ ]]; then
        err_tee "[ERROR] Could not re-read PR #${pr_number}'s head commit"
        log_section_end "PR CHECKS" "${logfile}" "1"
        exit 1
      fi
    done

    local checks_out checks_rc no_ci=0
    checks_out=$(gh pr checks "${pr_number}" --repo "${pr_repo}" 2>&1)
    checks_rc=$?
    echo "${checks_out}" >>"${logfile}"

    # (2) "no checks reported": CI not registered yet (just pushed) or a repo without CI.
    if [[ ${checks_rc} -ne 0 && ${checks_rc} -ne 8 && "${checks_out}" == *"no checks reported"* ]]; then
      local commit_date commit_epoch="" age=0
      commit_date=$(_pr_view "${pr_number}" commits '.commits[-1].committedDate') || commit_date=""
      commit_epoch=$(date -u -d "${commit_date}" +%s 2>/dev/null) ||
        commit_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${commit_date}" +%s 2>/dev/null) || commit_epoch=""
      # An unreadable commit date counts as fresh: fail closed (refuse) rather than merge unchecked.
      [[ -n "${commit_epoch}" ]] && age=$(($(date -u +%s) - commit_epoch))
      if [[ ${wait_checks} -eq 0 && (-z "${commit_epoch}" || ${age} -lt ${appear_max}) ]]; then
        err_tee "[ERROR] PR #${pr_number} has no checks on ${head_sha:0:7} yet and its head commit is recent -- CI may not have registered"
        err_tee "[ERROR] Rerun with --wait-checks (waits up to ${appear_max}s for checks to appear)"
        log_section_end "PR CHECKS" "${logfile}" "1"
        exit 1
      fi
      waited=0
      while [[ ${wait_checks} -eq 1 && ${checks_rc} -ne 0 && ${checks_rc} -ne 8 && "${checks_out}" == *"no checks reported"* && ${waited} -lt ${appear_max} ]]; do
        echo "PR #${pr_number} has no checks on ${head_sha:0:7} yet -- waiting for CI to register (${waited}/${appear_max}s)" | tee -a "${logfile}"
        sleep "${poll}"
        waited=$((waited + step))
        checks_out=$(gh pr checks "${pr_number}" --repo "${pr_repo}" 2>&1)
        checks_rc=$?
        echo "${checks_out}" >>"${logfile}"
      done
      if [[ ${checks_rc} -ne 0 && ${checks_rc} -ne 8 && "${checks_out}" == *"no checks reported"* ]]; then
        echo "[WARN] No checks on ${head_sha:0:7} after ${waited}s -- treating as no CI" | tee -a "${logfile}"
        checks_rc=0
        no_ci=1
      fi
    fi

    if [[ ${checks_rc} -eq 8 && ${wait_checks} -eq 1 ]]; then
      echo "PR #${pr_number} checks pending -- waiting (gh pr checks --watch)" | tee -a "${logfile}"
      gh pr checks "${pr_number}" --repo "${pr_repo}" --watch --fail-fast 2>&1 | tee -a "${logfile}"
      checks_rc=${PIPESTATUS[0]}
    fi
    if [[ ${checks_rc} -ne 0 ]]; then
      if [[ ${checks_rc} -eq 8 ]]; then
        err_tee "[ERROR] PR #${pr_number} checks are still pending -- rerun with --wait-checks, or wait for CI"
      else
        err_tee "[ERROR] PR #${pr_number} checks are not green (gh pr checks exit ${checks_rc}) -- fix CI before merging"
      fi
      log_section_end "PR CHECKS" "${logfile}" "1"
      exit 1
    fi

    # (3) The head must still be the one that was checked (a push can land mid-wait).
    local head_now
    head_now=$(_pr_view "${pr_number}" headRefOid .headRefOid) || head_now=""
    if [[ "${head_now}" != "${head_sha}" ]]; then
      err_tee "[ERROR] PR #${pr_number} head moved from ${head_sha:0:7} to ${head_now:0:7} while checks ran -- rerun to verify the new head"
      log_section_end "PR CHECKS" "${logfile}" "1"
      exit 1
    fi
    [[ ${no_ci} -eq 0 ]] && echo "[OK] PR #${pr_number} checks passed on ${head_sha:0:7}" | tee -a "${logfile}"
    log_section_end "PR CHECKS" "${logfile}" "0"
  fi
  echo "" | tee -a "${logfile}"

  # --match-head-commit: gh refuses the merge if the head is no longer the commit verified above.
  local merge_args=("${pr_number}" --repo "${pr_repo}" "--${method}" --match-head-commit "${head_sha}")

  if [[ ${dry_run} -eq 1 ]]; then
    echo "=== DRY RUN -- nothing merged ===" | tee -a "${logfile}"
    echo "" | tee -a "${logfile}"
    echo "Would run: gh pr merge ${merge_args[*]}" | tee -a "${logfile}"
    for m in "${retarget[@]}"; do
      echo "Would run: gh pr edit ${m} --repo ${pr_repo} --base ${base_branch}" | tee -a "${logfile}"
    done
    [[ ${delete_branch} -eq 1 ]] &&
      echo "Would delete branch: ${head_branch} in ${head_repo}" | tee -a "${logfile}"
    exit 0
  fi

  if [[ "${method}" != "merge" ]]; then
    echo "[WARN] --${method} flattens PR #${pr_number} into commits that can't be reverted as one unit." | tee -a "${logfile}"
    echo "       A merge commit would stay revertable with rollback_merge.sh --revert." | tee -a "${logfile}"
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
  # No verified tag, no merge: a remote merge can't be undone by a local reset.
  log_section_start "PRE-MERGE RECOVERY POINT" "${logfile}"
  local base_tip tag_tip
  base_tip=""
  if git fetch --quiet "${CGW_REMOTE}" "${base_branch}" >>"${logfile}" 2>&1; then
    base_tip=$(git rev-parse --verify --quiet "refs/remotes/${CGW_REMOTE}/${base_branch}^{commit}") || base_tip=""
  fi
  CGW_BACKUP_TAG=""
  [[ -n "${base_tip}" ]] && cgw_create_backup_tag merge "${base_tip}" >/dev/null
  tag_tip=""
  [[ -n "${CGW_BACKUP_TAG}" ]] && tag_tip=$(git rev-parse --verify --quiet "refs/tags/${CGW_BACKUP_TAG}^{commit}") || tag_tip=""
  if [[ -z "${base_tip}" || "${tag_tip}" != "${base_tip}" ]]; then
    log_section_end "PRE-MERGE RECOVERY POINT" "${logfile}" "1"
    err_tee "[ERROR] Could not fetch ${CGW_REMOTE}/${base_branch} and tag its tip -- refusing to merge without a recovery point"
    exit 1
  fi
  echo "[OK] Recovery point: ${CGW_BACKUP_TAG} -> ${base_tip:0:7}" | tee -a "${logfile}"
  log_section_end "PRE-MERGE RECOVERY POINT" "${logfile}" "0"

  # [3/4] Merge
  log_section_start "GH PR MERGE" "${logfile}"
  if gh pr merge "${merge_args[@]}" 2>&1 | tee -a "${logfile}"; then
    log_section_end "GH PR MERGE" "${logfile}" "0"
  else
    log_section_end "GH PR MERGE" "${logfile}" "1"
    err "gh pr merge failed -- check log: ${logfile}"
    exit 1
  fi

  # A merge queue or auto-merge makes gh exit 0 before the PR is actually merged: re-read the state
  # and, if it is not MERGED, leave the retarget/delete (which assume a merged PR) to the user.
  local post_state
  post_state=$(_pr_view "${pr_number}" state .state) || post_state=""
  if [[ "${post_state}" != "MERGED" ]]; then
    echo "[!] PR #${pr_number} is ${post_state:-in an unknown state}, not merged yet (merge queue or auto-merge pending)" | tee -a "${logfile}"
    echo "    Skipping --retarget and --delete-branch; rerun them once the PR shows MERGED." | tee -a "${logfile}"
    echo "Full log: ${logfile}"
    exit 0
  fi
  echo "[OK] Merged PR #${pr_number} into ${base_branch} (--${method})" | tee -a "${logfile}"
  echo "" | tee -a "${logfile}"

  # [4/4] Retarget stacked PRs, then optionally delete the head branch.
  # Order matters: deleting the head first would auto-close PRs still based on it.
  local failed=0
  if [[ ${#retarget[@]} -gt 0 ]]; then
    log_section_start "RETARGET STACKED PRS" "${logfile}"
    for m in "${retarget[@]}"; do
      if gh pr edit "${m}" --repo "${pr_repo}" --base "${base_branch}" 2>&1 | tee -a "${logfile}"; then
        echo "[OK] Retargeted PR #${m} onto ${base_branch}" | tee -a "${logfile}"
      else
        err_tee "[ERROR] Failed to retarget PR #${m} -- PR #${pr_number} is already merged; retarget manually:"
        err_tee "        gh pr edit ${m} --repo ${pr_repo} --base ${base_branch}"
        failed=1
      fi
    done
    log_section_end "RETARGET STACKED PRS" "${logfile}" "${failed}"
  fi

  if [[ ${delete_branch} -eq 1 ]]; then
    if [[ ${failed} -eq 1 ]]; then
      err_tee "[WARN] Skipping --delete-branch: a stacked PR could still be based on ${head_branch}"
    else
      log_section_start "DELETE HEAD BRANCH" "${logfile}"
      # head_repo, not pr_repo: for a cross-repository PR the branch lives in the head repository.
      if gh api --method DELETE "repos/${head_repo}/git/refs/heads/${head_branch}" 2>&1 | tee -a "${logfile}"; then
        echo "[OK] Deleted remote branch ${head_branch} (${head_repo})" | tee -a "${logfile}"
        log_section_end "DELETE HEAD BRANCH" "${logfile}" "0"
      else
        err_tee "[ERROR] Could not delete remote branch ${head_branch} in ${head_repo} (already gone, or no permission)"
        failed=1
        log_section_end "DELETE HEAD BRANCH" "${logfile}" "1"
      fi
    fi
  fi

  local merge_sha
  merge_sha=$(_pr_view "${pr_number}" mergeCommit .mergeCommit.oid) || merge_sha=""
  echo "" | tee -a "${logfile}"
  if [[ -n "${merge_sha}" && "${merge_sha}" != "null" ]]; then
    echo "Merge commit: ${merge_sha}" | tee -a "${logfile}"
    if [[ "${method}" == "merge" ]]; then
      echo "Undo (history-preserving): ./scripts/git/rollback_merge.sh --revert --target ${merge_sha}" | tee -a "${logfile}"
    fi
  fi
  echo "Full log: ${logfile}"
  [[ ${failed} -eq 0 ]]
}

main "${@}"
