#!/usr/bin/env bash
# cherry_pick_commits.sh - Cherry-pick specific commits from source to target branch
# Purpose: Cherry-pick commits with validation and automatic backup
# Usage: ./scripts/git/cherry_pick_commits.sh [OPTIONS]
#
# Globals:
#   SCRIPT_DIR            - Directory containing this script
#   PROJECT_ROOT          - Auto-detected git repo root (set by _config.sh)
#   logfile               - Set by init_logging
#   CGW_SOURCE_BRANCH     - Source branch (commits come from here; default: development)
#   CGW_TARGET_BRANCH     - Target branch (commits go here; default: main)
#   CGW_DEV_ONLY_FILES    - Space-separated dev-only file patterns (warns if commit touches these)
# Arguments:
#   --non-interactive    Skip prompts; requires --commit
#   --commit <hash>      Commit hash to cherry-pick (skips interactive selection)
#   --only <pathspec>    Partial pick: keep only files matching pathspec (repeatable).
#                        Applies with --no-commit, drops unselected paths, commits
#                        the rest with the original message + a partial-pick note.
#                        Conflicts abort cleanly (no hand-over in partial mode).
#   --dry-run            Show commit details without cherry-picking
#   --source <branch>    Override source branch for this invocation
#   --target <branch>    Override target branch for this invocation
#   -h, --help           Show help
# Returns:
#   0 on success, 1 on failure or conflict

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git/_common.sh
source "${SCRIPT_DIR}/_common.sh"

init_logging "cherry_pick_commits"
ensure_no_stale_index_lock || exit 1

_cp_original_branch=""
_cp_did_checkout_target=0

_cleanup_cherry_pick() {
  local current
  current=$(git branch --show-current 2>/dev/null || true)
  if [[ ${_cp_did_checkout_target} -eq 1 ]] && [[ -n "${_cp_original_branch}" ]] &&
    [[ "${current}" != "${_cp_original_branch}" ]]; then
    echo "" >&2
    echo "[!] Interrupted -- you are on branch: ${current}" >&2
    echo "  Returning to: ${_cp_original_branch}" >&2
    if git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1; then
      git cherry-pick --abort 2>/dev/null || true
    fi
    git checkout "${_cp_original_branch}" 2>/dev/null || true
  fi
}
trap _cleanup_cherry_pick EXIT INT TERM

main() {
  local non_interactive=0
  local dry_run=0
  local commit_hash_flag=""
  local only_paths=()
  local src_branch="${CGW_SOURCE_BRANCH}"
  local tgt_branch="${CGW_TARGET_BRANCH}"

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --help | -h)
        echo "Usage: ./scripts/git/cherry_pick_commits.sh [OPTIONS]"
        echo ""
        echo "Cherry-pick a commit from source branch to target branch with validation."
        echo ""
        echo "Options:"
        echo "  --non-interactive    Skip prompts; requires --commit"
        echo "  --commit <hash>      Commit hash to cherry-pick (skips interactive selection)"
        echo "  --only <pathspec>    Cherry-pick only files matching pathspec (repeatable)."
        echo "                       Unselected paths are dropped; the commit keeps the"
        echo "                       original message plus a partial-pick note. On conflict"
        echo "                       the partial pick aborts (nothing applied)."
        echo "  --dry-run            Show commit details without cherry-picking"
        echo "  --source <branch>    Override source branch for this invocation"
        echo "  --target <branch>    Override target branch for this invocation"
        echo "  -h, --help           Show this help"
        echo ""
        echo "Configuration:"
        echo "  CGW_SOURCE_BRANCH     Branch commits come from (default: development)"
        echo "  CGW_TARGET_BRANCH     Branch commits go to (default: main)"
        echo "  CGW_DEV_ONLY_FILES    Dev-only paths to warn about (default: empty)"
        echo ""
        echo "Environment:"
        echo "  CGW_NON_INTERACTIVE=1   Same as --non-interactive"
        exit 0
        ;;
      --non-interactive)
        non_interactive=1
        CGW_NON_INTERACTIVE=1
        ;;
      --dry-run) dry_run=1 ;;
      --commit)
        commit_hash_flag="${2:-}"
        shift
        ;;
      --only)
        if [[ -z "${2:-}" ]] || [[ "${2:0:2}" == "--" ]]; then
          err "--only requires a pathspec argument"
          exit 1
        fi
        only_paths+=("$2")
        shift
        ;;
      --source)
        src_branch="${2:-}"
        if [[ -z "${src_branch}" ]]; then
          err "--source requires a branch name"
          exit 1
        fi
        shift
        ;;
      --target)
        tgt_branch="${2:-}"
        if [[ -z "${tgt_branch}" ]]; then
          err "--target requires a branch name"
          exit 1
        fi
        shift
        ;;
      *)
        err "Unknown flag: $1"
        exit 1
        ;;
    esac
    shift
  done

  [[ "${CGW_NON_INTERACTIVE:-0}" == "1" ]] && non_interactive=1

  validate_branch_pair "${src_branch}" "${tgt_branch}"

  {
    echo "========================================="
    echo "Cherry-Pick Commits Log"
    echo "========================================="
    echo "Start Time: $(date)"
    echo "Working Directory: ${PROJECT_ROOT}"
  } >"$logfile"

  echo "=== Cherry-Pick Commits: ${src_branch} -> ${tgt_branch} ===" | tee -a "$logfile"
  echo "" | tee -a "$logfile"

  cd "${PROJECT_ROOT}" || {
    err "Cannot find project root"
    exit 1
  }

  # [1/6] Run validation
  cgw_run_pre_op_validation "cherry-pick" "${src_branch}" "${tgt_branch}" "$logfile" || exit 1
  echo "" | tee -a "$logfile"

  # [2/6] Store current branch and checkout target
  log_section_start "GIT CHECKOUT TARGET" "$logfile"

  local original_branch
  original_branch=$(git branch --show-current)
  _cp_original_branch="${original_branch}"

  if [[ -z "${original_branch}" ]]; then
    err_tee "[FAIL] Failed to determine current branch"
    log_section_end "GIT CHECKOUT TARGET" "$logfile" "1"
    exit 1
  fi

  echo "Current branch: ${original_branch}" | tee -a "$logfile"

  if ! run_git_with_logging "GIT CHECKOUT" "$logfile" checkout "${tgt_branch}"; then
    err_tee "[FAIL] Failed to checkout ${tgt_branch} branch"
    exit 1
  fi
  _cp_did_checkout_target=1

  log_section_end "GIT CHECKOUT TARGET" "$logfile" "0"
  echo "" | tee -a "$logfile"

  # [3/6] Show recent source branch commits
  if [[ -z "${commit_hash_flag}" ]]; then
    echo "[3/6] Recent commits on ${src_branch} branch:"
    echo "===================================="
    git log "${src_branch}" --oneline -20 --no-merges
    echo "===================================="
    echo ""
  fi

  # [4/6] Get commit hash
  local commit_hash
  if [[ -n "${commit_hash_flag}" ]]; then
    commit_hash="${commit_hash_flag}"
    echo "[4/6] Using --commit: ${commit_hash}" | tee -a "$logfile"
  elif [[ ${non_interactive} -eq 1 ]]; then
    echo "[FAIL] [Non-interactive] --commit <hash> is required" >&2
    git checkout "${original_branch}"
    exit 1
  else
    echo "[4/6] Select commit to cherry-pick..."
    echo ""
    read -e -r -p "Enter commit hash (or 'cancel' to abort): " commit_hash

    if [[ "${commit_hash}" == "cancel" ]]; then
      echo ""
      log_message "Cherry-pick cancelled" "${logfile}"
      git checkout "${original_branch}"
      exit 0
    fi
  fi

  if ! git rev-parse "${commit_hash}" >/dev/null 2>&1; then
    log_message "[FAIL] ERROR: Invalid commit hash: ${commit_hash}" "${logfile}"
    git checkout "${original_branch}"
    exit 1
  fi

  # Validate commit is on source branch
  if ! git merge-base --is-ancestor "${commit_hash}" "${src_branch}" 2>/dev/null; then
    echo "[!] WARNING: ${commit_hash} is not an ancestor of ${src_branch}" | tee -a "$logfile"
    if ! cgw_confirm "Continue anyway?" --non-interactive abort; then
      log_message "Cherry-pick cancelled" "${logfile}"
      git checkout "${original_branch}"
      exit 0
    fi
  fi

  echo ""
  echo "Selected commit:"
  git log "${commit_hash}" --oneline -1
  echo ""
  echo "Commit details:"
  git show "${commit_hash}" --stat
  echo ""

  # --only: partition the commit's files into picked vs skipped. git itself
  # applies the pathspecs (globs, dirs, :(...) magic all work), so selection
  # semantics match every other git path argument.
  local -a _all_files=() _sel_files=() _skip_files=()
  if [[ ${#only_paths[@]} -gt 0 ]]; then
    local _pf
    while IFS= read -r -d '' _pf; do
      _all_files+=("${_pf}")
    done < <(git diff-tree --no-commit-id --name-only -r -z "${commit_hash}")
    while IFS= read -r -d '' _pf; do
      _sel_files+=("${_pf}")
    done < <(git diff-tree --no-commit-id --name-only -r -z "${commit_hash}" -- "${only_paths[@]}")

    if [[ ${#_sel_files[@]} -eq 0 ]]; then
      err_tee "[FAIL] --only matched no files in ${commit_hash}"
      err_tee "  Commit touches: ${_all_files[*]+"${_all_files[*]}"}"
      git checkout "${original_branch}"
      exit 1
    fi

    local _af _matched
    for _af in "${_all_files[@]}"; do
      _matched=0
      for _pf in "${_sel_files[@]}"; do
        if [[ "${_af}" == "${_pf}" ]]; then
          _matched=1
          break
        fi
      done
      [[ ${_matched} -eq 0 ]] && _skip_files+=("${_af}")
    done

    echo "Partial pick (--only): ${#_sel_files[@]} of ${#_all_files[@]} file(s)" | tee -a "$logfile"
    for _pf in "${_sel_files[@]}"; do
      echo "  + ${_pf}" | tee -a "$logfile"
    done
    for _af in "${_skip_files[@]+"${_skip_files[@]}"}"; do
      echo "  - ${_af} (skipped)" | tee -a "$logfile"
    done
    echo ""
  fi

  if [[ ${dry_run} -eq 1 ]]; then
    echo "=== DRY RUN -- no changes made ===" | tee -a "$logfile"
    if [[ ${#only_paths[@]} -gt 0 ]]; then
      echo "Would partially cherry-pick ${commit_hash} (${#_sel_files[@]} of ${#_all_files[@]} files)" | tee -a "$logfile"
    else
      echo "Would cherry-pick: ${commit_hash}" | tee -a "$logfile"
    fi
    git checkout "${original_branch}"
    exit 0
  fi

  # File set the pick will actually land: the --only selection when partial,
  # otherwise the whole commit. Both guards below check this set, so a
  # dev-only or local-only file that --only excludes no longer warns/blocks.
  local _pick_files_nl
  if [[ ${#only_paths[@]} -gt 0 ]]; then
    _pick_files_nl=$(printf '%s\n' "${_sel_files[@]}")
  else
    _pick_files_nl=$(git show "${commit_hash}" --name-only --format="")
  fi

  # Check if the incoming file set modifies dev-only files (configurable warning)
  if [[ -n "${CGW_DEV_ONLY_FILES}" ]]; then
    local has_excluded_files=0
    local -a _dev_arr=()
    read -r -a _dev_arr <<<"${CGW_DEV_ONLY_FILES}" || true
    # Use grep -xF (exact, fixed-string, full-line match) so filenames with
    # regex metacharacters (dots, brackets, plus signs) are not misinterpreted,
    # and 'tests/' does not match 'more_tests/'.
    for dev_file in "${_dev_arr[@]+"${_dev_arr[@]}"}"; do
      if grep -qxF "${dev_file}" <<<"${_pick_files_nl}"; then
        has_excluded_files=1
        break
      fi
    done

    if [[ ${has_excluded_files} -eq 1 ]]; then
      echo "[!] WARNING: This commit modifies configured dev-only files"
      echo "Dev-only files (CGW_DEV_ONLY_FILES):"
      for dev_file in "${_dev_arr[@]+"${_dev_arr[@]}"}"; do
        grep -xF "${dev_file}" <<<"${_pick_files_nl}" || true
      done
      echo ""
      if ! cgw_confirm "Continue anyway?" --non-interactive abort; then
        echo ""
        log_message "Cherry-pick cancelled" "${logfile}"
        git checkout "${original_branch}"
        exit 0
      fi
    fi
  fi

  # Refuse to cherry-pick a change set that carries local-only files onto this
  # branch (they must not enter shared history). Partial picks guard only the
  # selected subset. Override with CGW_ALLOW_LOCAL_FILES_IN_MERGE=1.
  local _guard_failed=0
  if [[ ${#only_paths[@]} -gt 0 ]]; then
    cgw_guard_incoming_local_files list "${_sel_files[@]}" || _guard_failed=1
  else
    cgw_guard_incoming_local_files cherry-pick "${commit_hash}" || _guard_failed=1
  fi
  if [[ ${_guard_failed} -eq 1 ]]; then
    log_message "Cherry-pick cancelled (local-only files)" "${logfile}"
    git checkout "${original_branch}"
    exit 1
  fi

  # [5/6] Create backup tag
  log_section_start "CREATE BACKUP TAG" "$logfile"

  cgw_create_backup_tag cherry-pick
  local backup_tag="${CGW_BACKUP_TAG}"
  log_section_end "CREATE BACKUP TAG" "$logfile" "0"
  echo "" | tee -a "$logfile"

  # [6/6] Cherry-pick
  log_section_start "GIT CHERRY-PICK" "$logfile"

  if [[ ${#only_paths[@]} -gt 0 ]]; then
    # Partial pick: apply without committing, drop unselected paths, commit
    # the rest under the original message plus a partial-pick note.
    if ! run_git_with_logging "GIT CHERRY-PICK NO-COMMIT" "$logfile" cherry-pick --no-commit "${commit_hash}"; then
      log_section_end "GIT CHERRY-PICK" "$logfile" "1"
      echo "" | tee -a "$logfile"
      err_tee "[FAIL] Partial cherry-pick hit conflicts -- aborting, nothing applied"
      err_tee "  A partial pick has no conflict hand-over: run a full pick (its conflict"
      err_tee "  flow pauses for manual resolution), or pick by hand:"
      err_tee "    git cherry-pick -n ${commit_hash}   # then resolve, prune paths, commit"
      if ! git cherry-pick --abort 2>/dev/null; then
        # --abort refuses after a --no-commit conflict; restore manually.
        # Safe: pre-op validation guaranteed a clean tree, so HEAD is the
        # exact pre-pick state and nothing but the failed pick is discarded.
        git cherry-pick --quit 2>/dev/null || true
        git reset --hard HEAD >/dev/null 2>&1 || true
      fi
      git checkout "${original_branch}"
      exit 1
    fi

    # Drop unselected paths from index and working tree. Pre-op validation
    # guarantees the tree was clean, so every change present came from this
    # pick; restoring a skipped path can never lose unrelated work.
    local _drop
    for _drop in "${_skip_files[@]+"${_skip_files[@]}"}"; do
      git reset -q HEAD -- "${_drop}" 2>/dev/null || true
      if git cat-file -e "HEAD:${_drop}" 2>/dev/null; then
        git checkout -q HEAD -- "${_drop}"
      else
        rm -f -- "${_drop}" # the commit added this file; it wasn't selected
      fi
    done

    if git diff --cached --quiet; then
      log_section_end "GIT CHERRY-PICK" "$logfile" "1"
      err_tee "[FAIL] Selected path(s) produce no change on this branch (already applied?)"
      git cherry-pick --quit 2>/dev/null || true
      git checkout "${original_branch}"
      exit 1
    fi

    local _orig_msg _short_hash
    _orig_msg=$(git log -1 --format=%B "${commit_hash}")
    _short_hash=$(git rev-parse --short "${commit_hash}")
    if ! run_git_with_logging "GIT COMMIT PARTIAL PICK" "$logfile" commit \
      -m "${_orig_msg}" \
      -m "(partial cherry-pick of ${_short_hash} -- only: ${only_paths[*]})"; then
      log_section_end "GIT CHERRY-PICK" "$logfile" "1"
      err_tee "[FAIL] Committing the partial pick failed -- check output above"
      exit 1
    fi
  elif ! run_git_with_logging "GIT CHERRY-PICK COMMIT" "$logfile" cherry-pick "${commit_hash}"; then
    log_section_end "GIT CHERRY-PICK" "$logfile" "1"
    echo "" | tee -a "$logfile"
    echo "[!] Cherry-pick conflicts detected - analyzing..." | tee -a "$logfile"

    if ! cgw_resolve_safe_conflicts cherry-pick "${original_branch}"; then
      exit 1
    fi

    # All conflicts auto-resolved; cherry-pick is still paused — user must --continue.
    echo "" | tee -a "$logfile"
    echo "[OK] All conflicts auto-resolved. To complete the cherry-pick:" | tee -a "$logfile"
    echo "  git cherry-pick --continue" | tee -a "$logfile"
    echo "Backup available: git reset --hard ${backup_tag}" | tee -a "$logfile"
    exit 1
  fi

  trap - EXIT INT TERM
  log_section_end "GIT CHERRY-PICK" "$logfile" "0"
  echo "" | tee -a "$logfile"
  {
    echo "========================================"
    echo "[CHERRY-PICK SUMMARY]"
    echo "========================================"
  } | tee -a "$logfile"
  echo "[OK] CHERRY-PICK SUCCESSFUL" | tee -a "$logfile"
  echo "" | tee -a "$logfile"
  line="$(git log -1 --oneline)"
  echo "  Cherry-picked: ${line}" | tee -a "${logfile}"
  echo "  Original commit: ${commit_hash}" | tee -a "$logfile"
  if [[ ${#only_paths[@]} -gt 0 ]]; then
    echo "  Partial pick: ${#_sel_files[@]} of ${#_all_files[@]} file(s) (--only)" | tee -a "$logfile"
  fi
  echo "  Backup tag: ${backup_tag}" | tee -a "$logfile"
  echo "" | tee -a "$logfile"
  echo "Next steps:" | tee -a "$logfile"
  echo "  1. Review: git show HEAD" | tee -a "$logfile"
  echo "  2. Push: ./scripts/git/push_validated.sh" | tee -a "$logfile"
  echo "  Rollback: git reset --hard ${backup_tag}" | tee -a "$logfile"
  {
    echo ""
    echo "End Time: $(date)"
  } | tee -a "$logfile"
  echo "" | tee -a "$logfile"
  echo "Full log: $logfile"
}

main "$@"
